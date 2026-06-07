defmodule Atp.Transport.SessionIntake do
  @moduledoc false

  alias Atp.Identity.{Agent, Idempotency}
  alias Atp.Transport.DurableLedger

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

  def finish(%Agent{}, _status, _body, prepared) when is_map(prepared) do
    Idempotency.complete_prepared_after_commit(prepared, &complete_queued_intake/3)
  end

  defp complete_queued_intake(status, body, _commit_value) do
    {:ok, status, body}
  end
end
