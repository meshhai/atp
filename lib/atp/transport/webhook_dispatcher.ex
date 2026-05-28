defmodule Atp.Transport.WebhookDispatcher do
  @moduledoc "Periodic dispatcher for durable ATP webhook delivery rows."

  use GenServer

  alias Atp.Transport.WebhookDelivery

  @default_batch_size 50
  @default_interval_ms 5_000

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
      interval_ms: option(opts, :interval_ms, @default_interval_ms)
    }

    if state.enabled? and state.dispatch_on_start?, do: schedule(0)

    {:ok, state}
  end

  @impl true
  def handle_info(:dispatch_due, %{enabled?: true} = state) do
    WebhookDelivery.deliver_due(limit: state.batch_size)
    schedule(state.interval_ms)

    {:noreply, state}
  end

  def handle_info(:dispatch_due, state), do: {:noreply, state}

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
