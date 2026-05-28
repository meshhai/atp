defmodule Atp.Transport.WebhookDispatcher do
  @moduledoc "Periodic dispatcher for durable ATP webhook delivery rows."

  use GenServer

  alias Atp.Transport
  alias Atp.Transport.{DeliveryClaim, WebhookDelivery}

  @default_batch_size 50
  @default_concurrency 5
  @default_interval_ms 5_000
  @default_lease_seconds 60
  @default_task_supervisor __MODULE__.TaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, genserver_opts(opts))
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?: option(opts, :enabled, true),
      dispatch_on_start?: option(opts, :dispatch_on_start?, true),
      batch_size: option(opts, :batch_size, @default_batch_size),
      interval_ms: option(opts, :interval_ms, @default_interval_ms),
      lease_seconds: option(opts, :lease_seconds, @default_lease_seconds),
      concurrency: option(opts, :concurrency, @default_concurrency),
      task_supervisor: option(opts, :task_supervisor, @default_task_supervisor),
      dispatching?: false,
      batch_remaining: 0,
      due_exhausted?: false,
      in_flight: %{}
    }

    if state.enabled? and state.dispatch_on_start?, do: schedule(0)

    {:ok, state}
  end

  @impl true
  def handle_info(:dispatch_due, %{enabled?: true} = state) do
    schedule(state.interval_ms)

    {:noreply, state |> start_dispatch_batch() |> start_available_workers()}
  end

  def handle_info(:dispatch_due, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     state
     |> finish_worker(ref, result)
     |> start_available_workers()
     |> maybe_finish_dispatch_batch()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    {:noreply,
     state
     |> finish_worker(ref, {:error, reason})
     |> start_available_workers()
     |> maybe_finish_dispatch_batch()}
  end

  defp start_dispatch_batch(%{dispatching?: true} = state), do: state

  defp start_dispatch_batch(%{batch_size: batch_size} = state) do
    %{
      state
      | dispatching?: true,
        batch_remaining: batch_size,
        due_exhausted?: false
    }
  end

  defp start_available_workers(%{dispatching?: false} = state), do: state

  defp start_available_workers(%{batch_remaining: 0} = state), do: state

  defp start_available_workers(%{due_exhausted?: true} = state), do: state

  defp start_available_workers(%{in_flight: in_flight, concurrency: concurrency} = state)
       when map_size(in_flight) >= concurrency do
    state
  end

  defp start_available_workers(state) do
    callers = [self() | Process.get(:"$callers", [])]

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Process.put(:"$callers", callers)
        dispatch_one(state.lease_seconds)
      end)

    state
    |> put_in([:in_flight, task.ref], task.pid)
    |> Map.update!(:batch_remaining, &(&1 - 1))
    |> start_available_workers()
  end

  defp dispatch_one(lease_seconds) do
    case Transport.claim_due_webhook_delivery(lease_seconds: lease_seconds) do
      {:ok, nil} ->
        :idle

      {:ok, %DeliveryClaim{} = claim} ->
        {:delivered, claim.delivery.id, WebhookDelivery.deliver_claim(claim)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_worker(%{in_flight: in_flight} = state, ref, result) do
    case Map.pop(in_flight, ref) do
      {nil, _in_flight} ->
        state

      {_pid, in_flight} ->
        state
        |> Map.put(:in_flight, in_flight)
        |> apply_worker_result(result)
    end
  end

  defp apply_worker_result(state, :idle), do: %{state | due_exhausted?: true}
  defp apply_worker_result(state, _result), do: state

  defp maybe_finish_dispatch_batch(%{dispatching?: false} = state), do: state

  defp maybe_finish_dispatch_batch(%{in_flight: in_flight, due_exhausted?: true} = state)
       when map_size(in_flight) == 0 do
    finish_dispatch_batch(state)
  end

  defp maybe_finish_dispatch_batch(%{in_flight: in_flight, batch_remaining: 0} = state)
       when map_size(in_flight) == 0 do
    finish_dispatch_batch(state)
  end

  defp maybe_finish_dispatch_batch(state), do: state

  defp finish_dispatch_batch(state) do
    %{state | dispatching?: false, batch_remaining: 0, due_exhausted?: false}
  end

  defp genserver_opts(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> []
      {:ok, name} -> [name: name]
      :error -> [name: __MODULE__]
    end
  end

  defp option(opts, key, default) do
    opts
    |> Keyword.get(key, config_option(key, default))
  end

  defp config_option(key, default) do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp schedule(interval_ms) do
    Process.send_after(self(), :dispatch_due, interval_ms)
  end
end
