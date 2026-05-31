defmodule Atp.Transport.Runtime do
  @moduledoc """
  Live carrier-plane seam for ATP session operations.

  The durable ledger remains the source of truth. Runtime processes own active
  session lifecycle and serialize selected live carrier operations.
  """

  require Logger

  alias Atp.Identity.Agent
  alias Atp.Transport.{DurableLedger, Ledger, SessionIntake}
  alias Atp.Transport.Runtime.SessionServer

  @type api_result :: {:ok, pos_integer(), map()} | {:error, term()}
  @type session_summary :: SessionServer.summary()

  @session_registry Atp.Transport.Runtime.SessionRegistry
  @session_supervisor Atp.Transport.Runtime.SessionSupervisor

  @spec open_session(Agent.t(), map(), String.t() | nil, String.t()) :: api_result()
  def open_session(%Agent{} = initiator, params, idempotency_key, route) when is_map(params) do
    with {:ok, status, body, prepared} <-
           DurableLedger.open_session(initiator, params, idempotency_key, route) do
      SessionIntake.finish(initiator, status, body, prepared)
    end
    |> warm_pending_opening_session()
  end

  @spec accept_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) :: api_result()
  def accept_session(%Agent{} = recipient, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) do
    recipient
    |> Ledger.accept_session(session_id, params, idempotency_key, route)
    |> handle_session_id_accept(session_id)
  end

  @spec reject_session(Agent.t(), String.t(), map(), String.t() | nil, String.t()) :: api_result()
  def reject_session(%Agent{} = recipient, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) do
    recipient
    |> Ledger.reject_session(session_id, params, idempotency_key, route)
    |> handle_session_id_reject(session_id)
  end

  @spec send_session_message(Agent.t(), String.t(), map(), String.t() | nil, String.t()) ::
          api_result()
  def send_session_message(%Agent{} = sender, session_id, params, idempotency_key, route)
      when is_binary(session_id) and is_map(params) do
    with :ok <-
           DurableLedger.preflight_session_message(
             sender,
             session_id,
             params,
             idempotency_key,
             route
           ),
         {:ok, pid} <- ensure_session_started(session_id) do
      SessionServer.send_session_message(pid, sender, params, idempotency_key, route)
    end
  end

  @spec get_session(Agent.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(%Agent{} = agent, session_id) when is_binary(session_id) do
    case Ledger.get_session(agent, session_id) do
      {:ok, %{"session" => %{"status" => "open"}} = body} ->
        _result = ensure_session_started(session_id)
        {:ok, body}

      result ->
        result
    end
  end

  @spec ack_delivery(Agent.t(), String.t(), map(), String.t() | nil, String.t()) :: api_result()
  def ack_delivery(%Agent{} = agent, delivery_id, params, idempotency_key, route)
      when is_binary(delivery_id) and is_map(params) do
    opening_session_id = opening_session_id_for_ack(agent, delivery_id, params)

    agent
    |> Ledger.ack_delivery(delivery_id, params, idempotency_key, route)
    |> handle_opening_session_ack(params, opening_session_id)
  end

  @spec ensure_session_started(String.t()) ::
          {:ok, pid()} | {:error, :not_found | :session_not_open}
  def ensure_session_started(session_id) when is_binary(session_id) do
    with {:ok, _session} <- Ledger.fetch_open_session(session_id),
         {:ok, pid} <- start_session_process(session_id),
         {:ok, _state} <- SessionServer.refresh_session(pid) do
      {:ok, pid}
    end
  end

  @spec list_active_sessions() :: [session_summary()]
  def list_active_sessions do
    if is_pid(Process.whereis(@session_registry)) do
      @session_registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.sort_by(fn {session_id, _pid} -> session_id end)
      |> Enum.flat_map(&active_session_summary/1)
    else
      []
    end
  end

  defp normalize_session_start({:ok, pid}), do: {:ok, pid}
  defp normalize_session_start({:error, {:already_started, pid}}), do: {:ok, pid}
  defp normalize_session_start({:error, reason}), do: {:error, reason}

  defp active_session_summary({_session_id, pid}) do
    case safe_session_summary(pid) do
      {:ok, summary} -> [summary]
      {:error, _reason} -> []
    end
  end

  defp safe_session_summary(pid) when is_pid(pid) do
    SessionServer.summary(pid)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp warm_pending_opening_session(
         {:ok, _status, %{"session" => %{"id" => session_id, "status" => "pending"}}} =
           result
       ) do
    case safe_start_session_process(session_id) do
      {:ok, _pid} -> :ok
      {:error, reason} -> log_session_start_failure(session_id, reason)
    end

    result
  end

  defp warm_pending_opening_session(result), do: result

  defp safe_start_session_process(session_id) do
    with {:ok, pid} <- start_session_process(session_id),
         {:ok, _state} <- SessionServer.refresh_session(pid) do
      {:ok, pid}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp start_session_process(session_id) do
    session_id
    |> SessionServer.child_spec()
    |> then(&DynamicSupervisor.start_child(@session_supervisor, &1))
    |> normalize_session_start()
  end

  defp opening_session_id_for_ack(%Agent{} = agent, delivery_id, %{"status" => status})
       when status in ~w(accepted rejected failed) do
    Ledger.opening_session_id_for_delivery(agent, delivery_id)
  end

  defp opening_session_id_for_ack(%Agent{}, _delivery_id, _params), do: nil

  defp handle_opening_session_ack(
         {:ok, _status, _body} = result,
         %{"status" => "accepted"},
         session_id
       )
       when is_binary(session_id) do
    case safe_ensure_session_started(session_id) do
      {:ok, _pid} -> :ok
      {:error, reason} -> log_session_warm_failure(session_id, reason)
    end

    result
  end

  defp handle_opening_session_ack(
         {:ok, _status, _body} = result,
         %{"status" => status},
         session_id
       )
       when status in ~w(rejected failed) and is_binary(session_id) do
    stop_session_process(session_id)
    result
  end

  defp handle_opening_session_ack({:error, :message_expired} = result, _params, session_id)
       when is_binary(session_id) do
    stop_session_process(session_id)
    result
  end

  defp handle_opening_session_ack(result, _params, _session_id), do: result

  defp handle_session_id_accept({:ok, _status, _body} = result, session_id) do
    case safe_ensure_session_started(session_id) do
      {:ok, _pid} -> :ok
      {:error, reason} -> log_session_warm_failure(session_id, reason)
    end

    result
  end

  defp handle_session_id_accept(result, _session_id), do: result

  defp handle_session_id_reject({:ok, _status, _body} = result, session_id) do
    stop_session_process(session_id)
    result
  end

  defp handle_session_id_reject({:error, :message_expired} = result, session_id) do
    stop_session_process(session_id)
    result
  end

  defp handle_session_id_reject(result, _session_id), do: result

  defp safe_ensure_session_started(session_id) do
    ensure_session_started(session_id)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp log_session_warm_failure(session_id, reason) do
    Logger.warning(
      "Failed to warm accepted ATP session runtime session_id=#{session_id} reason=#{inspect(reason)}"
    )
  end

  defp stop_session_process(session_id) do
    if is_pid(Process.whereis(@session_registry)) and
         is_pid(Process.whereis(@session_supervisor)) do
      case Registry.lookup(@session_registry, session_id) do
        [{pid, _metadata}] -> safe_stop_session_process(pid)
        [] -> :ok
      end
    else
      :ok
    end
  end

  defp safe_stop_session_process(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp log_session_start_failure(session_id, reason) do
    Logger.warning(
      "Failed to start pending ATP session runtime session_id=#{session_id} reason=#{inspect(reason)}"
    )
  end
end
