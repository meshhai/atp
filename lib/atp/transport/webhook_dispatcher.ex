defmodule Atp.Transport.WebhookDispatcher do
  @moduledoc "Periodic dispatcher for durable ATP webhook delivery rows."

  use GenServer

  alias Atp.Transport.WebhookDelivery

  @default_batch_size 50
  @default_interval_ms 5_000

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
      batch_size: option(opts, :batch_size, @default_batch_size),
      interval_ms: option(opts, :interval_ms, @default_interval_ms),
      timer_ref: nil
    }

    {:ok, schedule_initial_dispatch(state)}
  end

  @impl true
  def handle_info(:dispatch_due, %{enabled?: true} = state) do
    {:noreply, dispatch_due(state)}
  end

  def handle_info(:dispatch_due, state), do: {:noreply, state}

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

    WebhookDelivery.deliver_due(limit: state.batch_size)

    schedule(state, state.interval_ms)
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
