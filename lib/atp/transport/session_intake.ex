defmodule Atp.Transport.SessionIntake do
  @moduledoc false

  alias Atp.Identity.{Agent, Idempotency}
  alias Atp.Repo
  alias Atp.Transport.{DurableLedger, Message, Response, Session, WebhookDelivery}

  @type api_result :: {:ok, pos_integer(), map()} | {:error, term()}

  @spec finish(
          Agent.t(),
          pos_integer(),
          map(),
          DurableLedger.session_intake_after_commit()
        ) :: api_result()
  def finish(%Agent{}, status, body, nil) when is_integer(status) and is_map(body) do
    {:ok, status, body}
  end

  def finish(%Agent{} = viewer, _status, _body, prepared) when is_map(prepared) do
    Idempotency.complete_prepared_after_commit(prepared, fn status, body, commit_value ->
      finish_prepared_webhook_delivery(viewer, status, body, commit_value)
    end)
  end

  defp finish_prepared_webhook_delivery(%Agent{}, status, body, {_session_id, nil}) do
    {:ok, status, body}
  end

  defp finish_prepared_webhook_delivery(
         %Agent{} = viewer,
         _status,
         _body,
         {session_id, delivery_id}
       )
       when is_binary(session_id) and is_binary(delivery_id) do
    with {:ok, %Message{} = message} <- WebhookDelivery.deliver_now(delivery_id) do
      session = Repo.get!(Session, session_id)

      {:ok, 201, Response.session_message(session, message, viewer)}
    end
  end
end
