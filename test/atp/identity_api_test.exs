defmodule Atp.IdentityAPITest do
  use Atp.ConnCase, async: true

  alias Atp.Identity.IdempotencyKey
  alias Atp.Repo

  test "an account registers an agent and reads back its stable address", %{conn: conn} do
    account = create_account!(conn, %{"name" => "Dev Network"})
    account_token = account["account_api_key"]["token"]

    agent =
      conn
      |> authorize(account_token)
      |> idempotency_key("register-alpha")
      |> post("/api/agents", %{
        "display_name" => "Alpha",
        "description" => "Polling runtime"
      })
      |> json_response(201)

    assert String.starts_with?(agent["id"], "agt_")
    assert agent["address"] == "atp://agent/#{agent["id"]}"
    assert agent["display_name"] == "Alpha"
    assert agent["description"] == "Polling runtime"
    assert String.starts_with?(agent["agent_api_key"]["token"], "agk_")

    fetched =
      build_conn()
      |> authorize(account_token)
      |> get("/api/agents/#{agent["id"]}")
      |> json_response(200)

    assert fetched["id"] == agent["id"]
    assert fetched["address"] == agent["address"]
    assert fetched["active_agent_key_id"] == agent["agent_api_key"]["id"]
  end

  test "agent registration idempotently replays the same request and conflicts on body drift", %{
    conn: conn
  } do
    account = create_account!(conn)
    token = account["account_api_key"]["token"]
    params = %{"display_name" => "Alpha"}

    first =
      build_conn()
      |> authorize(token)
      |> idempotency_key("register-alpha")
      |> post("/api/agents", params)
      |> json_response(201)

    replay =
      build_conn()
      |> authorize(token)
      |> idempotency_key("register-alpha")
      |> post("/api/agents", params)
      |> json_response(201)

    assert replay == first

    conflict =
      build_conn()
      |> authorize(token)
      |> idempotency_key("register-alpha")
      |> post("/api/agents", %{"display_name" => "Changed"})
      |> json_response(409)

    assert error_code(conflict) == "idempotency_conflict"
  end

  test "credential-bearing idempotency responses replay without raw token storage", %{conn: conn} do
    account = create_account!(conn)
    token = account["account_api_key"]["token"]
    params = %{"display_name" => "Alpha"}

    first =
      build_conn()
      |> authorize(token)
      |> idempotency_key("safe-register-alpha")
      |> post("/api/agents", params)
      |> json_response(201)

    stored_registration = Repo.get_by!(IdempotencyKey, key: "safe-register-alpha")

    refute stored_registration.response_body
           |> inspect()
           |> String.contains?(first["agent_api_key"]["token"])

    replay =
      build_conn()
      |> authorize(token)
      |> idempotency_key("safe-register-alpha")
      |> post("/api/agents", params)
      |> json_response(201)

    assert replay == first

    rotated =
      build_conn()
      |> authorize(token)
      |> idempotency_key("safe-rotate-alpha")
      |> post("/api/agents/#{first["id"]}/keys", %{})
      |> json_response(201)

    stored_rotation = Repo.get_by!(IdempotencyKey, key: "safe-rotate-alpha")

    refute stored_rotation.response_body
           |> inspect()
           |> String.contains?(rotated["token"])

    rotation_replay =
      build_conn()
      |> authorize(token)
      |> idempotency_key("safe-rotate-alpha")
      |> post("/api/agents/#{first["id"]}/keys", %{})
      |> json_response(201)

    assert rotation_replay == rotated
  end

  test "public account creation is locked to free plan and plan limits are enforced", %{
    conn: conn
  } do
    attempted_basic = create_account!(conn, %{"plan" => "basic"})

    assert attempted_basic["plan"] == "free"

    attempted_basic_token = attempted_basic["account_api_key"]["token"]
    register_agent!(attempted_basic_token, "attempted-basic-1", %{"display_name" => "One"})
    register_agent!(attempted_basic_token, "attempted-basic-2", %{"display_name" => "Two"})

    attempted_basic_limit =
      build_conn()
      |> authorize(attempted_basic_token)
      |> idempotency_key("attempted-basic-3")
      |> post("/api/agents", %{"display_name" => "Three"})
      |> json_response(422)

    assert error_code(attempted_basic_limit) == "plan_limit_exceeded"

    free = create_account!(build_conn(), %{"plan" => "free"})
    free_token = free["account_api_key"]["token"]

    register_agent!(free_token, "free-1", %{"display_name" => "One"})
    register_agent!(free_token, "free-2", %{"display_name" => "Two"})

    free_limit =
      build_conn()
      |> authorize(free_token)
      |> idempotency_key("free-3")
      |> post("/api/agents", %{"display_name" => "Three"})
      |> json_response(422)

    assert error_code(free_limit) == "plan_limit_exceeded"

    basic = create_account!(build_conn())
    promote_to_basic!(basic)
    basic_token = basic["account_api_key"]["token"]

    for index <- 1..10 do
      register_agent!(basic_token, "basic-#{index}", %{"display_name" => "Agent #{index}"})
    end

    basic_limit =
      build_conn()
      |> authorize(basic_token)
      |> idempotency_key("basic-11")
      |> post("/api/agents", %{"display_name" => "Eleven"})
      |> json_response(422)

    assert error_code(basic_limit) == "plan_limit_exceeded"
  end

  test "account and agent management return explicit API errors", %{conn: conn} do
    invalid_account =
      conn
      |> post("/api/accounts", %{})
      |> json_response(422)

    assert error_code(invalid_account) == "invalid_account"

    unauthorized =
      build_conn()
      |> post("/api/agents", %{"display_name" => "No Auth"})
      |> json_response(401)

    assert error_code(unauthorized) == "unauthorized"

    invalid_bearer =
      build_conn()
      |> authorize("not-a-real-token")
      |> get("/api/agents/agt_missing")
      |> json_response(401)

    assert error_code(invalid_bearer) == "unauthorized"

    account = create_account!(build_conn())
    token = account["account_api_key"]["token"]

    missing_key =
      build_conn()
      |> authorize(token)
      |> post("/api/agents", %{"display_name" => "Missing Key"})
      |> json_response(400)

    assert error_code(missing_key) == "idempotency_key_required"

    blank_key =
      build_conn()
      |> authorize(token)
      |> idempotency_key("   ")
      |> post("/api/agents", %{"display_name" => "Blank Key"})
      |> json_response(400)

    assert error_code(blank_key) == "idempotency_key_required"

    invalid_agent =
      build_conn()
      |> authorize(token)
      |> idempotency_key("invalid-agent")
      |> post("/api/agents", %{"display_name" => String.duplicate("x", 121)})
      |> json_response(422)

    assert error_code(invalid_agent) == "invalid_request"

    missing_agent =
      build_conn()
      |> authorize(token)
      |> get("/api/agents/agt_missing")
      |> json_response(404)

    assert error_code(missing_agent) == "not_found"

    missing_rotation =
      build_conn()
      |> authorize(token)
      |> idempotency_key("rotate-missing")
      |> post("/api/agents/agt_missing/keys", %{})
      |> json_response(404)

    assert error_code(missing_rotation) == "not_found"
  end

  test "account keys manage agents and agent keys cannot manage unrelated agents", %{conn: conn} do
    account = create_account!(conn)
    account_token = account["account_api_key"]["token"]
    alpha = register_agent!(account_token, "register-alpha", %{"display_name" => "Alpha"})
    beta = register_agent!(account_token, "register-beta", %{"display_name" => "Beta"})
    alpha_token = alpha["agent_api_key"]["token"]

    agent_key_create =
      build_conn()
      |> authorize(alpha_token)
      |> idempotency_key("agent-key-create")
      |> post("/api/agents", %{"display_name" => "Gamma"})
      |> json_response(403)

    assert error_code(agent_key_create) == "account_key_required"

    agent_key_read =
      build_conn()
      |> authorize(alpha_token)
      |> get("/api/agents/#{beta["id"]}")
      |> json_response(403)

    assert error_code(agent_key_read) == "account_key_required"

    rotated =
      build_conn()
      |> authorize(account_token)
      |> idempotency_key("rotate-alpha")
      |> post("/api/agents/#{alpha["id"]}/keys", %{})
      |> json_response(201)

    assert String.starts_with?(rotated["token"], "agk_")
    refute rotated["id"] == alpha["agent_api_key"]["id"]

    fetched =
      build_conn()
      |> authorize(account_token)
      |> get("/api/agents/#{alpha["id"]}")
      |> json_response(200)

    assert fetched["active_agent_key_id"] == rotated["id"]
  end

  defp promote_to_basic!(account) do
    Atp.Identity.Account
    |> Atp.Repo.get!(account["id"])
    |> Ecto.Changeset.change(plan: "basic")
    |> Atp.Repo.update!()
  end
end
