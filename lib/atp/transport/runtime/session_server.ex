defmodule Atp.Transport.Runtime.SessionServer do
  @moduledoc "Supervised live owner for one open ATP session."

  use GenServer

  alias Atp.Transport.{Ledger, Session}
  alias Atp.Transport.Runtime.SessionState

  @registry Atp.Transport.Runtime.SessionRegistry

  @spec child_spec(String.t()) :: Supervisor.child_spec()
  def child_spec(session_id) when is_binary(session_id) do
    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [session_id]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via_tuple(session_id))
  end

  @spec send_session_message(
          GenServer.server(),
          Atp.Identity.Agent.t(),
          map(),
          String.t() | nil,
          String.t()
        ) :: Ledger.api_result()
  def send_session_message(server, sender, params, idempotency_key, route) do
    with {:ok, status, body, prepared, dispatch_ticket} <-
           prepare_session_message_send(server, sender, params, idempotency_key, route) do
      finish_session_message_send(server, sender, status, body, prepared, dispatch_ticket)
    end
  end

  @spec refresh_session(GenServer.server()) :: {:ok, SessionState.t()} | {:error, term()}
  def refresh_session(server) do
    GenServer.call(server, :refresh_session)
  end

  @type summary :: SessionState.summary()

  @spec summary(GenServer.server()) :: {:ok, summary()}
  def summary(server) do
    GenServer.call(server, :summary)
  end

  @impl true
  def init(session_id) do
    case Ledger.fetch_runtime_session(session_id) do
      {:ok, %Session{} = session} ->
        {:ok, session |> SessionState.from_session() |> schedule_lifecycle_timer()}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:send_session_message, sender, params, idempotency_key, route},
        from,
        %SessionState{session_id: session_id} = state
      ) do
    result =
      Ledger.prepare_session_message_send(sender, session_id, params, idempotency_key, route)

    state = refresh_state_after_send(result, session_id, state)
    {reply, state} = maybe_enqueue_webhook_dispatch(result, from, state)

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:refresh_session, _from, %SessionState{session_id: session_id} = state) do
    case refresh_state(session_id, state) do
      {:ok, refreshed_state} -> {:reply, {:ok, refreshed_state}, refreshed_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:summary, _from, %SessionState{} = state) do
    {:reply, {:ok, SessionState.summary(state, self())}, state}
  end

  def handle_call(
        {:await_webhook_dispatch_turn, ticket},
        from,
        %SessionState{} = state
      )
      when is_reference(ticket) do
    cond do
      not webhook_dispatch_ticket?(state, ticket) ->
        {:reply, {:error, :webhook_dispatch_ticket_not_found}, state}

      webhook_dispatch_queue_head?(state, ticket) and is_nil(state.webhook_dispatch_owner) ->
        {reply, state} = grant_webhook_dispatch_turn(state, ticket)
        {:reply, reply, state}

      true ->
        state =
          %SessionState{
            state
            | webhook_dispatch_waiters: Map.put(state.webhook_dispatch_waiters, ticket, from)
          }
          |> grant_next_webhook_dispatch_turn()

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(
        {:release_webhook_dispatch_turn, ticket, release_token},
        %SessionState{webhook_dispatch_owner: {ticket, release_token}} = state
      ) do
    {:noreply,
     state
     |> remove_webhook_dispatch_ticket(ticket)
     |> grant_next_webhook_dispatch_turn()}
  end

  def handle_cast({:release_webhook_dispatch_turn, _ticket, _release_token}, state) do
    {:noreply, state}
  end

  defp refresh_state_after_send({:ok, _status, _body, _prepared}, session_id, state) do
    {:ok, %Session{} = session} = Ledger.fetch_runtime_session(session_id)
    state |> SessionState.refresh_from_session(session) |> schedule_lifecycle_timer()
  end

  defp refresh_state_after_send({:error, _reason}, _session_id, state), do: state

  defp prepare_session_message_send(server, sender, params, idempotency_key, route) do
    GenServer.call(
      server,
      {:send_session_message, sender, params, idempotency_key, route},
      :infinity
    )
  end

  defp finish_session_message_send(_server, sender, status, body, prepared, nil) do
    Ledger.finish_prepared_session_message_send(sender, status, body, prepared)
  end

  defp finish_session_message_send(server, sender, status, body, prepared, dispatch_ticket) do
    with {:ok, release_token} <-
           GenServer.call(
             server,
             {:await_webhook_dispatch_turn, dispatch_ticket},
             :infinity
           ) do
      try do
        Ledger.finish_prepared_session_message_send(sender, status, body, prepared)
      after
        GenServer.cast(
          server,
          {:release_webhook_dispatch_turn, dispatch_ticket, release_token}
        )
      end
    end
  end

  defp maybe_enqueue_webhook_dispatch({:ok, status, body, prepared}, from, state) do
    if ordered_webhook_dispatch?(prepared, state.session_id) do
      ticket = make_ref()
      {caller_pid, _tag} = from
      monitor_ref = Process.monitor(caller_pid)

      state = %SessionState{
        state
        | webhook_dispatch_queue: :queue.in(ticket, state.webhook_dispatch_queue),
          webhook_dispatch_ticket_monitors:
            Map.put(state.webhook_dispatch_ticket_monitors, ticket, monitor_ref),
          webhook_dispatch_monitor_tickets:
            Map.put(state.webhook_dispatch_monitor_tickets, monitor_ref, ticket)
      }

      {{:ok, status, body, prepared, ticket}, state}
    else
      {{:ok, status, body, prepared, nil}, state}
    end
  end

  defp maybe_enqueue_webhook_dispatch({:error, _reason} = result, _from, state) do
    {result, state}
  end

  defp ordered_webhook_dispatch?(
         %{commit_value: {session_id, webhook_delivery_id}},
         session_id
       )
       when is_binary(webhook_delivery_id) do
    true
  end

  defp ordered_webhook_dispatch?(_prepared, _session_id), do: false

  @impl true
  def handle_info(
        :expire_pending_opening_session,
        %SessionState{session_id: session_id, status: "pending"} = state
      ) do
    now = DateTime.utc_now(:microsecond)

    case Ledger.expire_pending_opening_session(session_id, now) do
      {:ok, %Session{} = session} ->
        refreshed_state =
          state
          |> cancel_lifecycle_timer()
          |> SessionState.refresh_from_session(session)

        {:stop, :normal, refreshed_state}

      {:error, :opening_session_not_due} ->
        {:noreply, state |> clear_lifecycle_timer() |> schedule_lifecycle_timer()}

      {:error, _reason} ->
        {:stop, :normal, cancel_lifecycle_timer(state)}
    end
  end

  def handle_info(:expire_pending_opening_session, %SessionState{} = state) do
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, _reason},
        %SessionState{} = state
      ) do
    case Map.fetch(state.webhook_dispatch_monitor_tickets, monitor_ref) do
      {:ok, ticket} ->
        {:noreply,
         state
         |> remove_webhook_dispatch_ticket(ticket)
         |> grant_next_webhook_dispatch_turn()}

      :error ->
        {:noreply, state}
    end
  end

  defp refresh_state(session_id, %SessionState{} = state) do
    with {:ok, %Session{} = session} <- Ledger.fetch_runtime_session(session_id) do
      refreshed_state =
        state
        |> cancel_lifecycle_timer()
        |> SessionState.refresh_from_session(session)
        |> schedule_lifecycle_timer()

      {:ok, refreshed_state}
    end
  end

  defp cancel_lifecycle_timer(%SessionState{lifecycle_timer_ref: nil} = state), do: state

  defp cancel_lifecycle_timer(%SessionState{lifecycle_timer_ref: timer_ref} = state) do
    _result = Process.cancel_timer(timer_ref)
    %SessionState{state | lifecycle_timer_ref: nil}
  end

  defp clear_lifecycle_timer(%SessionState{} = state) do
    %SessionState{state | lifecycle_timer_ref: nil}
  end

  defp schedule_lifecycle_timer(
         %SessionState{
           status: "pending",
           lifecycle_deadline_at: %DateTime{} = deadline_at
         } = state
       ) do
    delay_ms = max(DateTime.diff(deadline_at, DateTime.utc_now(:microsecond), :millisecond), 0)
    timer_ref = Process.send_after(self(), :expire_pending_opening_session, delay_ms)

    %SessionState{state | lifecycle_timer_ref: timer_ref}
  end

  defp schedule_lifecycle_timer(%SessionState{} = state), do: state

  defp webhook_dispatch_queue_head?(%SessionState{} = state, ticket) do
    case :queue.peek(state.webhook_dispatch_queue) do
      {:value, ^ticket} -> true
      _other -> false
    end
  end

  defp grant_next_webhook_dispatch_turn(%SessionState{webhook_dispatch_owner: nil} = state) do
    case :queue.peek(state.webhook_dispatch_queue) do
      {:value, ticket} ->
        cond do
          not webhook_dispatch_ticket?(state, ticket) ->
            state
            |> drop_webhook_dispatch_queue_head()
            |> grant_next_webhook_dispatch_turn()

          waiting_webhook_dispatch?(state, ticket) ->
            {_reply, state} = grant_webhook_dispatch_turn(state, ticket)
            state

          true ->
            state
        end

      :empty ->
        state
    end
  end

  defp grant_next_webhook_dispatch_turn(%SessionState{} = state), do: state

  defp webhook_dispatch_ticket?(%SessionState{} = state, ticket) do
    case Map.fetch(state.webhook_dispatch_ticket_monitors, ticket) do
      {:ok, _monitor_ref} -> true
      :error -> false
    end
  end

  defp waiting_webhook_dispatch?(%SessionState{} = state, ticket) do
    case Map.fetch(state.webhook_dispatch_waiters, ticket) do
      {:ok, _from} -> true
      :error -> false
    end
  end

  defp grant_webhook_dispatch_turn(%SessionState{} = state, ticket) do
    release_token = make_ref()

    {waiter, waiters} = Map.pop(state.webhook_dispatch_waiters, ticket)
    state = drop_webhook_dispatch_queue_head(state)

    state = %SessionState{
      state
      | webhook_dispatch_owner: {ticket, release_token},
        webhook_dispatch_waiters: waiters
    }

    reply = {:ok, release_token}

    if waiter do
      GenServer.reply(waiter, reply)
    end

    {reply, state}
  end

  defp drop_webhook_dispatch_queue_head(%SessionState{} = state) do
    {_, queue} = :queue.out(state.webhook_dispatch_queue)
    %SessionState{state | webhook_dispatch_queue: queue}
  end

  defp remove_webhook_dispatch_ticket(%SessionState{} = state, ticket) do
    {monitor_ref, ticket_monitors} =
      Map.pop(state.webhook_dispatch_ticket_monitors, ticket)

    monitor_tickets =
      if is_reference(monitor_ref) do
        Process.demonitor(monitor_ref, [:flush])
        Map.delete(state.webhook_dispatch_monitor_tickets, monitor_ref)
      else
        state.webhook_dispatch_monitor_tickets
      end

    owner =
      case state.webhook_dispatch_owner do
        {^ticket, _release_token} -> nil
        other -> other
      end

    %SessionState{
      state
      | webhook_dispatch_owner: owner,
        webhook_dispatch_queue: remove_webhook_dispatch_ticket_from_queue(state, ticket),
        webhook_dispatch_waiters: Map.delete(state.webhook_dispatch_waiters, ticket),
        webhook_dispatch_ticket_monitors: ticket_monitors,
        webhook_dispatch_monitor_tickets: monitor_tickets
    }
  end

  defp remove_webhook_dispatch_ticket_from_queue(%SessionState{} = state, ticket) do
    state.webhook_dispatch_queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == ticket))
    |> :queue.from_list()
  end

  defp via_tuple(session_id), do: {:via, Registry, {@registry, session_id}}
end
