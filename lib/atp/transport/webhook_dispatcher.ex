defmodule Atp.Transport.WebhookDispatcher do
  @moduledoc "Periodic dispatcher for durable ATP webhook delivery rows."

  use GenServer

  alias Atp.Transport.{DeliveryClaim, DurableLedger, Message, WebhookDelivery}

  @default_batch_size 50
  @default_interval_ms 5_000
  @default_max_in_flight 10
  @default_shutdown_wait_ms 1_000
  @default_task_supervisor __MODULE__.TaskSupervisor
  @task_claim_key {__MODULE__, :delivery_claim}
  @telemetry_prefix [:atp, :transport, :webhook_dispatcher]

  @spec wakeup(GenServer.server() | nil) :: :ok
  def wakeup(server \\ configured_name()) do
    wakeup_dispatcher(server)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, genserver_opts(opts))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    task_supervisor = option(opts, :task_supervisor, @default_task_supervisor)

    state = %{
      enabled?: option(opts, :enabled, true),
      dispatch_on_start?: option(opts, :dispatch_on_start?, true),
      batch_size: positive_integer_option(opts, :batch_size, @default_batch_size),
      interval_ms: positive_integer_option(opts, :interval_ms, @default_interval_ms),
      max_in_flight: positive_integer_option(opts, :max_in_flight, @default_max_in_flight),
      shutdown_wait_ms:
        non_negative_integer_option(opts, :shutdown_wait_ms, @default_shutdown_wait_ms),
      task_supervisor: task_supervisor,
      timer_ref: nil,
      in_flight: monitor_existing_tasks(task_supervisor),
      pending_dispatches: 0
    }

    {:ok, schedule_initial_dispatch(state)}
  end

  @impl true
  def handle_info(:dispatch_due, %{enabled?: true} = state) do
    {:noreply, dispatch_due(state, :timer)}
  end

  def handle_info(:dispatch_due, state), do: {:noreply, state}

  def handle_info({ref, {:task_exit, result}}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    %{claim: claim} = Map.fetch!(in_flight, ref)
    Process.demonitor(ref, [:flush])

    state =
      state
      |> complete_task(ref)
      |> emit_task_exit(claim, result)
      |> start_available_tasks()

    {:noreply, state}
  end

  def handle_info({ref, result}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    %{claim: claim} = Map.fetch!(in_flight, ref)
    Process.demonitor(ref, [:flush])

    state =
      state
      |> complete_task(ref)
      |> emit_attempt_finish(claim, result)
      |> start_available_tasks()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    %{claim: claim} = Map.fetch!(in_flight, ref)

    {state, result} = record_running_task_exit(state, ref, reason)

    state =
      state
      |> complete_task(ref)
      |> emit_task_exit(claim, result)
      |> start_available_tasks()

    {:noreply, state}
  end

  @impl true
  def handle_cast(:dispatch_wakeup, %{enabled?: true} = state) do
    {:noreply, dispatch_due(state, :wakeup)}
  end

  def handle_cast(:dispatch_wakeup, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state
    |> cancel_timer()
    |> wait_for_in_flight()

    :ok
  end

  defp genserver_opts(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> []
      {:ok, name} -> [name: name]
      :error -> [name: configured_name()]
    end
  end

  defp option(opts, key, default) do
    opts
    |> Keyword.get(key, config_option(key, default))
  end

  defp positive_integer_option(opts, key, default) do
    case option(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp non_negative_integer_option(opts, key, default) do
    case option(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp config_option(key, default) do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp configured_name do
    config_option(:name, __MODULE__)
  end

  defp monitor_existing_tasks(task_supervisor) do
    task_supervisor
    |> task_supervisor_children()
    |> Map.new(&monitor_existing_task/1)
  end

  defp monitor_existing_task(pid) do
    {Process.monitor(pid), %{pid: pid, claim: task_delivery_claim(pid)}}
  end

  defp task_delivery_claim(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @task_claim_key, 0) do
          {_key, %DeliveryClaim{} = claim} -> claim
          _other -> nil
        end

      nil ->
        nil
    end
  end

  defp task_supervisor_children(task_supervisor) do
    Task.Supervisor.children(task_supervisor)
  catch
    :exit, _reason -> []
  end

  defp wakeup_dispatcher(nil), do: :ok

  defp wakeup_dispatcher(server) do
    GenServer.cast(server, :dispatch_wakeup)
  catch
    :exit, _reason -> :ok
  end

  defp schedule_initial_dispatch(%{enabled?: false} = state), do: state

  defp schedule_initial_dispatch(%{dispatch_on_start?: true} = state) do
    schedule(state, 0)
  end

  defp schedule_initial_dispatch(state) do
    schedule(state, state.interval_ms)
  end

  defp dispatch_due(state, trigger) do
    state = cancel_timer(state)

    state =
      state
      |> emit_scan(trigger)
      |> queue_dispatches()
      |> start_available_tasks()

    schedule(state, state.interval_ms)
  end

  defp queue_dispatches(state) do
    %{state | pending_dispatches: max(state.pending_dispatches, state.batch_size)}
  end

  defp start_available_tasks(state) do
    state
    |> available_task_count()
    |> start_tasks(state)
  end

  defp available_task_count(state) do
    state.max_in_flight
    |> Kernel.-(map_size(state.in_flight))
    |> min(state.pending_dispatches)
    |> max(0)
  end

  defp start_tasks(0, state), do: state

  defp start_tasks(count, state) do
    case DurableLedger.claim_due_webhook_delivery() do
      {:ok, nil} ->
        state
        |> emit_claim(:empty, nil)
        |> clear_pending_when_idle()

      {:ok, %DeliveryClaim{} = claim} ->
        state
        |> emit_claim(:claimed, claim)
        |> start_task(claim)
        |> then(&start_tasks(count - 1, &1))

      {:error, reason} ->
        state
        |> emit_claim(:error, nil, reason)
        |> Map.put(:pending_dispatches, 0)
    end
  end

  defp clear_pending_when_idle(%{in_flight: in_flight} = state) when map_size(in_flight) > 0 do
    state
  end

  defp clear_pending_when_idle(state), do: %{state | pending_dispatches: 0}

  defp start_task(state, %DeliveryClaim{} = claim) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        deliver_claim_safely(claim)
      end)

    state = %{
      state
      | in_flight: Map.put(state.in_flight, task.ref, %{pid: task.pid, claim: claim}),
        pending_dispatches: state.pending_dispatches - 1
    }

    emit_attempt_start(state, claim)
  end

  defp deliver_claim_safely(%DeliveryClaim{} = claim) do
    Process.put(@task_claim_key, claim)

    try do
      WebhookDelivery.deliver_claim(claim)
    rescue
      _exception ->
        record_sanitized_task_exit(claim)
    catch
      _kind, _reason ->
        record_sanitized_task_exit(claim)
    end
  end

  defp record_sanitized_task_exit(%DeliveryClaim{} = claim) do
    {:task_exit, WebhookDelivery.record_task_exit(claim)}
  rescue
    _exception ->
      {:task_exit, {:error, :task_exit_record_failed}}
  catch
    _kind, _reason ->
      {:task_exit, {:error, :task_exit_record_failed}}
  end

  defp record_running_task_exit(state, _ref, :normal), do: {state, {:ok, :normal}}
  defp record_running_task_exit(state, ref, _reason), do: record_durable_task_exit(state, ref)

  defp record_shutdown_task_exit(state, _ref, :normal), do: {state, {:ok, :normal}}
  defp record_shutdown_task_exit(state, _ref, :shutdown), do: {state, {:ok, :shutdown}}
  defp record_shutdown_task_exit(state, _ref, {:shutdown, _reason}), do: {state, {:ok, :shutdown}}
  defp record_shutdown_task_exit(state, ref, _reason), do: record_durable_task_exit(state, ref)

  defp record_durable_task_exit(%{in_flight: in_flight} = state, ref) do
    case Map.fetch!(in_flight, ref) do
      %{claim: %DeliveryClaim{} = claim} ->
        {state, WebhookDelivery.record_task_exit(claim)}

      %{claim: nil} ->
        {state, {:error, :unknown_claim}}
    end
  end

  defp complete_task(state, ref) do
    %{state | in_flight: Map.delete(state.in_flight, ref)}
  end

  defp wait_for_in_flight(%{shutdown_wait_ms: 0}), do: :ok

  defp wait_for_in_flight(state) do
    deadline_ms = System.monotonic_time(:millisecond) + state.shutdown_wait_ms
    wait_for_in_flight_until(state, deadline_ms)
  end

  defp wait_for_in_flight_until(%{in_flight: in_flight}, _deadline_ms)
       when map_size(in_flight) == 0 do
    :ok
  end

  defp wait_for_in_flight_until(%{in_flight: in_flight} = state, deadline_ms) do
    timeout_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    if timeout_ms == 0 do
      :ok
    else
      receive do
        {ref, {:task_exit, result}} when is_map_key(in_flight, ref) ->
          %{claim: claim} = Map.fetch!(in_flight, ref)
          Process.demonitor(ref, [:flush])

          state
          |> complete_task(ref)
          |> emit_task_exit(claim, result)
          |> wait_for_in_flight_until(deadline_ms)

        {ref, result} when is_map_key(in_flight, ref) ->
          %{claim: claim} = Map.fetch!(in_flight, ref)
          Process.demonitor(ref, [:flush])

          state
          |> complete_task(ref)
          |> emit_attempt_finish(claim, result)
          |> wait_for_in_flight_until(deadline_ms)

        {:DOWN, ref, :process, _pid, reason} when is_map_key(in_flight, ref) ->
          %{claim: claim} = Map.fetch!(in_flight, ref)
          {state, result} = record_shutdown_task_exit(state, ref, reason)

          state
          |> complete_task(ref)
          |> emit_task_exit(claim, result)
          |> wait_for_in_flight_until(deadline_ms)
      after
        timeout_ms -> :ok
      end
    end
  end

  defp schedule(state, interval_ms) do
    %{state | timer_ref: Process.send_after(self(), :dispatch_due, interval_ms)}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    _result = Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end

  defp emit_scan(state, trigger) do
    emit(
      [:scan],
      measurements(state),
      %{
        trigger: trigger,
        batch_size: state.batch_size
      }
    )

    state
  end

  defp emit_claim(state, result, claim, reason \\ nil) do
    emit(
      [:claim],
      measurements(state),
      claim_metadata(claim)
      |> Map.merge(%{result: result})
      |> maybe_put(:error_class, error_class(reason))
    )

    state
  end

  defp emit_attempt_start(state, %DeliveryClaim{} = claim) do
    emit([:attempt, :start], measurements(state), claim_metadata(claim))
    state
  end

  defp emit_attempt_finish(state, nil, _result), do: state

  defp emit_attempt_finish(state, %DeliveryClaim{} = claim, result) do
    emit(
      [:attempt, :finish],
      measurements(state),
      Map.merge(claim_metadata(claim), result_metadata(result))
    )

    state
  end

  defp emit_task_exit(state, nil, _result), do: state

  defp emit_task_exit(state, _claim, {:ok, status}) when status in [:normal, :shutdown], do: state

  defp emit_task_exit(state, %DeliveryClaim{} = claim, result) do
    emit(
      [:attempt, :exit],
      measurements(state),
      claim
      |> claim_metadata()
      |> Map.merge(result_metadata(result))
      |> Map.put(:error_class, "internal_task_exit")
    )

    state
  end

  defp emit(event_suffix, measurements, metadata) do
    :telemetry.execute(@telemetry_prefix ++ event_suffix, measurements, metadata)
  end

  defp measurements(state) do
    in_flight = map_size(state.in_flight)

    %{
      in_flight: in_flight,
      max_in_flight: state.max_in_flight,
      available_capacity: max(state.max_in_flight - in_flight, 0),
      pending_dispatches: state.pending_dispatches
    }
  end

  defp claim_metadata(nil), do: %{}

  defp claim_metadata(%DeliveryClaim{} = claim) do
    %{
      delivery_id: claim.delivery.id,
      message_id: claim.message.id,
      attempt_number: claim.attempt_number
    }
  end

  defp result_metadata({:ok, %Message{carrier_status: message_status}}) do
    %{
      result: result_from_message_status(message_status),
      message_status: message_status
    }
  end

  defp result_metadata({:ok, status}) when status in [:normal, :shutdown] do
    %{result: Atom.to_string(status)}
  end

  defp result_metadata({:error, reason}) do
    %{
      result: "error",
      error_class: error_class(reason)
    }
  end

  defp result_from_message_status("delivered"), do: "delivered"
  defp result_from_message_status("delivery_failed"), do: "failed"
  defp result_from_message_status("expired"), do: "failed"
  defp result_from_message_status("queued"), do: "retry_scheduled"
  defp result_from_message_status(status), do: status

  defp error_class(nil), do: nil
  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class(_reason), do: "internal_error"

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)
end
