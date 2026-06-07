defmodule Atp.Transport.WebhookDispatcher do
  @moduledoc "Periodic dispatcher for durable ATP webhook delivery rows."

  use GenServer

  alias Atp.Transport.{DeliveryClaim, DurableLedger, WebhookDelivery}

  @default_batch_size 50
  @default_interval_ms 5_000
  @default_max_in_flight 10
  @default_task_supervisor __MODULE__.TaskSupervisor

  @spec wakeup(GenServer.server() | nil) :: :ok
  def wakeup(server \\ configured_name()) do
    case dispatcher_pid(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :dispatch_wakeup)
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, genserver_opts(opts))
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?: option(opts, :enabled, true),
      dispatch_on_start?: option(opts, :dispatch_on_start?, true),
      batch_size: positive_integer_option(opts, :batch_size, @default_batch_size),
      interval_ms: positive_integer_option(opts, :interval_ms, @default_interval_ms),
      max_in_flight: positive_integer_option(opts, :max_in_flight, @default_max_in_flight),
      task_supervisor: option(opts, :task_supervisor, @default_task_supervisor),
      timer_ref: nil,
      in_flight: %{},
      pending_dispatches: 0
    }

    {:ok, schedule_initial_dispatch(state)}
  end

  @impl true
  def handle_info(:dispatch_due, %{enabled?: true} = state) do
    {:noreply, dispatch_due(state)}
  end

  def handle_info(:dispatch_due, state), do: {:noreply, state}

  def handle_info({ref, _result}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    Process.demonitor(ref, [:flush])

    state =
      state
      |> complete_task(ref)
      |> start_available_tasks()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{in_flight: in_flight} = state)
      when is_map_key(in_flight, ref) do
    state =
      state
      |> complete_task(ref)
      |> start_available_tasks()

    {:noreply, state}
  end

  @impl true
  def handle_cast(:dispatch_wakeup, %{enabled?: true} = state) do
    {:noreply, dispatch_due(state)}
  end

  def handle_cast(:dispatch_wakeup, state), do: {:noreply, state}

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

  defp config_option(key, default) do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp configured_name do
    config_option(:name, __MODULE__)
  end

  defp dispatcher_pid(nil), do: nil

  defp dispatcher_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp dispatcher_pid(name) when is_atom(name) do
    Process.whereis(name)
  end

  defp dispatcher_pid(_server), do: nil

  defp schedule_initial_dispatch(%{enabled?: false} = state), do: state

  defp schedule_initial_dispatch(%{dispatch_on_start?: true} = state) do
    schedule(state, 0)
  end

  defp schedule_initial_dispatch(state) do
    schedule(state, state.interval_ms)
  end

  defp dispatch_due(state) do
    state = cancel_timer(state)

    state =
      state
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
        %{state | pending_dispatches: 0}

      {:ok, %DeliveryClaim{} = claim} ->
        state
        |> start_task(claim)
        |> then(&start_tasks(count - 1, &1))

      {:error, _reason} ->
        %{state | pending_dispatches: 0}
    end
  end

  defp start_task(state, %DeliveryClaim{} = claim) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        WebhookDelivery.deliver_claim(claim)
      end)

    %{
      state
      | in_flight: Map.put(state.in_flight, task.ref, task.pid),
        pending_dispatches: state.pending_dispatches - 1
    }
  end

  defp complete_task(state, ref) do
    %{state | in_flight: Map.delete(state.in_flight, ref)}
  end

  defp schedule(state, interval_ms) do
    %{state | timer_ref: Process.send_after(self(), :dispatch_due, interval_ms)}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    _result = Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end
end
