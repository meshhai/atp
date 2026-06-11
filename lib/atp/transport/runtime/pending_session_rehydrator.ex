defmodule Atp.Transport.Runtime.PendingSessionRehydrator do
  @moduledoc "Restores pending ATP session processes so opening expiry timers are live."

  use GenServer

  require Logger

  alias Atp.Transport.DurableLedger
  alias Atp.Transport.Runtime.SessionServer

  @session_supervisor Atp.Transport.Runtime.SessionSupervisor
  @default_retry_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      session_supervisor: Keyword.get(opts, :session_supervisor, @session_supervisor),
      list_pending_session_ids:
        Keyword.get(opts, :list_pending_session_ids, &DurableLedger.list_pending_session_ids/0),
      retry_interval_ms: Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms)
    }

    {:ok, rehydrate_pending_sessions(state)}
  end

  @impl true
  def handle_info(:rehydrate_pending_sessions, state) do
    {:noreply, rehydrate_pending_sessions(state)}
  end

  defp rehydrate_pending_sessions(state) do
    case list_pending_session_ids(state) do
      {:ok, session_ids} ->
        results = Enum.map(session_ids, &start_pending_session(&1, state.session_supervisor))

        if Enum.any?(results, &match?({:error, _reason}, &1)) do
          schedule_retry(state)
        end

        state

      {:error, reason} ->
        Logger.warning(
          "Failed to list pending ATP sessions for runtime rehydration reason_class=#{error_class(reason)}"
        )

        schedule_retry(state)
        state
    end
  end

  defp list_pending_session_ids(%{list_pending_session_ids: list_pending_session_ids})
       when is_function(list_pending_session_ids, 0) do
    {:ok, list_pending_session_ids.()}
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_pending_session(session_id, session_supervisor) do
    session_id
    |> SessionServer.child_spec()
    |> then(&DynamicSupervisor.start_child(session_supervisor, &1))
    |> case do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to rehydrate pending ATP session runtime session_id=#{session_id} reason_class=#{error_class(reason)}"
        )

        {:error, reason}
    end
  end

  defp schedule_retry(%{retry_interval_ms: retry_interval_ms}) do
    Process.send_after(self(), :rehydrate_pending_sessions, retry_interval_ms)
  end

  defp error_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_class({:exception, _exception}), do: "exception"
  defp error_class({kind, _reason}) when kind in [:error, :exit, :throw], do: Atom.to_string(kind)
  defp error_class({_class, _reason}), do: "internal_error"
  defp error_class(_reason), do: "internal_error"
end
