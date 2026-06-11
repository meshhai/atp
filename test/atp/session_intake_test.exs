defmodule Atp.SessionIntakeTest do
  use Atp.DataCase, async: false

  alias Atp.Identity
  alias Atp.Identity.{Account, Agent, Idempotency}
  alias Atp.Repo
  alias Atp.Transport.{SessionIntake, WebhookDispatcher}

  test "prepared completion without webhook delivery commit does not wake dispatcher" do
    agent = create_agent!()
    suffix = System.unique_integer([:positive])
    route = "POST /api/sessions"
    key = "session-intake-without-webhook-#{suffix}"
    request = %{"session_id" => "ses_without_webhook_#{suffix}"}
    response_body = %{"session" => %{"id" => request["session_id"], "status" => "open"}}

    assert {:ok, 202, ^response_body, prepared} =
             Idempotency.run_prepared_after_commit(agent, route, key, request, fn ->
               {:ok, 202, response_body, :accepted_without_webhook}
             end)

    with_dispatcher_name(self(), fn ->
      assert {:ok, 202, ^response_body} =
               SessionIntake.finish(agent, 500, %{"ignored" => true}, prepared)

      refute_receive {:"$gen_cast", :dispatch_wakeup}, 50
    end)

    assert {:ok, 202, ^response_body} = Idempotency.preflight(agent, route, key, request)
  end

  defp create_agent! do
    {:ok, account_response} = Identity.create_account(%{"name" => "Session intake test"})
    account = Repo.get!(Account, account_response["id"])

    {:ok, 201, agent_response} =
      Identity.register_agent(account, %{}, "register-session-intake", "POST /api/agents")

    Repo.get!(Agent, agent_response["id"])
  end

  defp with_dispatcher_name(name, fun) when is_function(fun, 0) do
    original_config = Application.get_env(:atp, WebhookDispatcher)
    updated_config = Keyword.put(original_config || [], :name, name)

    Application.put_env(:atp, WebhookDispatcher, updated_config)

    try do
      fun.()
    after
      if is_nil(original_config) do
        Application.delete_env(:atp, WebhookDispatcher)
      else
        Application.put_env(:atp, WebhookDispatcher, original_config)
      end
    end
  end
end
