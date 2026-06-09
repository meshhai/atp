defmodule Atp.Transport.WebhookDispatcher.AttemptWorker do
  @moduledoc false

  use GenServer

  alias Atp.Transport.{DeliveryClaim, WebhookDelivery, WebhookDispatcher}

  @claim_key {WebhookDispatcher, :delivery_claim}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  @spec claim(pid()) :: DeliveryClaim.t() | nil
  def claim(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, @claim_key, 0) do
          {_key, %DeliveryClaim{} = claim} -> claim
          _other -> nil
        end

      nil ->
        nil
    end
  end

  @impl true
  def init(opts) do
    claim = Keyword.fetch!(opts, :claim)
    dispatcher = Keyword.fetch!(opts, :dispatcher)
    callers = Keyword.fetch!(opts, :callers)

    Process.put(@claim_key, claim)
    Process.put(:"$callers", callers)

    {:ok, %{claim: claim, dispatcher: dispatcher}, {:continue, :deliver}}
  end

  @impl true
  def handle_continue(:deliver, %{claim: claim, dispatcher: dispatcher} = state) do
    send(dispatcher, {self(), deliver_claim_safely(claim)})

    {:stop, :normal, state}
  end

  defp deliver_claim_safely(%DeliveryClaim{} = claim) do
    WebhookDelivery.deliver_claim(claim)
  rescue
    _exception ->
      record_sanitized_task_exit(claim)
  catch
    _kind, _reason ->
      record_sanitized_task_exit(claim)
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
end
