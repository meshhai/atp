defmodule Atp.SenderPolicyTest do
  use Atp.ConnCase, async: true

  alias Atp.Identity.Agent
  alias Atp.Transport.{SenderPolicies, SenderPolicy}

  test "sender policy changeset requires exactly one sender target" do
    no_target =
      SenderPolicy.changeset(%SenderPolicy{id: "spol_no_target"}, %{
        recipient_agent_id: "agt_recipient",
        effect: "allow"
      })

    refute no_target.valid?
    assert {"must set exactly one sender target", _meta} = no_target.errors[:sender_agent_id]

    both_targets =
      SenderPolicy.changeset(%SenderPolicy{id: "spol_both_targets"}, %{
        recipient_agent_id: "agt_recipient",
        sender_agent_id: "agt_sender",
        sender_account_id: "acct_sender",
        effect: "allow"
      })

    refute both_targets.valid?
    assert {"must set exactly one sender target", _meta} = both_targets.errors[:sender_agent_id]
  end

  test "sender policy API rejects malformed and missing target requests", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    recipient = register_agent!(account_token, "register-invalid-policy-recipient", %{})
    other_recipient = register_agent!(account_token, "register-invalid-policy-other", %{})

    missing_target =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-missing-target")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{"effect" => "allow"})
      |> json_response(422)

    assert error_code(missing_target) == "invalid_sender_policy"

    invalid_effect =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-invalid-effect")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "maybe",
        "sender_agent_id" => other_recipient["id"]
      })
      |> json_response(422)

    assert error_code(invalid_effect) == "invalid_sender_policy"

    wrong_agent =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-wrong-agent")
      |> put("/api/agents/#{other_recipient["id"]}/sender_policies", %{
        "effect" => "allow",
        "sender_agent_id" => other_recipient["id"]
      })
      |> json_response(404)

    assert error_code(wrong_agent) == "not_found"
  end

  test "sender policy API rejects missing sender agent or account targets", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    recipient = register_agent!(account_token, "register-missing-target-policy-recipient", %{})

    missing_agent =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-missing-agent")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "allow",
        "sender_agent_id" => "agt_missing"
      })
      |> json_response(404)

    assert error_code(missing_agent) == "not_found"

    missing_account =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-missing-account")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "allow",
        "sender_account_id" => "acct_missing"
      })
      |> json_response(404)

    assert error_code(missing_account) == "not_found"
  end

  test "sender policy upsert updates an existing target without duplicate rows", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    recipient = register_agent!(account_token, "register-upsert-policy-recipient", %{})
    sender = register_agent!(account_token, "register-upsert-policy-sender", %{})

    first =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-upsert-first")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "allow",
        "sender_agent_id" => sender["id"]
      })
      |> json_response(200)

    second =
      build_conn()
      |> authorize(recipient["agent_api_key"]["token"])
      |> idempotency_key("sender-policy-upsert-second")
      |> put("/api/agents/#{recipient["id"]}/sender_policies", %{
        "effect" => "block",
        "sender_agent_id" => sender["id"]
      })
      |> json_response(200)

    assert second["sender_policy"]["id"] == first["sender_policy"]["id"]
    assert second["sender_policy"]["effect"] == "block"
    assert Atp.Repo.aggregate(SenderPolicy, :count) == 1
  end

  test "sender policy upsert maps constraint failures to API errors", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    sender = register_agent!(account_token, "register-stale-recipient-policy-sender", %{})

    stale_recipient = %Agent{
      id: "agt_missing_recipient",
      account_id: account["id"],
      address: "atp://agent/agt_missing_recipient",
      status: "active"
    }

    assert {:error, :invalid_sender_policy} =
             SenderPolicies.upsert(stale_recipient, %{
               "effect" => "allow",
               "sender_agent_id" => sender["id"]
             })
  end

  test "sender policy response handles not-yet-persisted timestamps" do
    response =
      SenderPolicies.to_response(%SenderPolicy{
        id: "spol_unpersisted",
        recipient_agent_id: "agt_recipient",
        sender_agent_id: "agt_sender",
        effect: "allow"
      })

    assert get_in(response, ["sender_policy", "updated_at"]) == nil
  end
end
