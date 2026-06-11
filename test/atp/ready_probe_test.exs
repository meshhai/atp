defmodule Atp.ReadyProbeTest do
  use Atp.ConnCase, async: false

  alias Atp.Transport.WebhookDispatcher

  setup do
    old_config = Application.get_env(:atp, WebhookDispatcher)

    on_exit(fn ->
      Application.put_env(:atp, WebhookDispatcher, old_config)
    end)

    :ok
  end

  test "GET /ready returns public readiness JSON when this node can receive traffic", %{
    conn: conn
  } do
    response =
      conn
      |> get("/ready")
      |> json_response(200)

    assert response == %{
             "status" => "ok",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "disabled"
             }
           }
  end

  test "GET /ready returns sanitized 503 JSON when a required check fails", %{conn: conn} do
    Application.put_env(:atp, WebhookDispatcher,
      enabled: true,
      name: :missing_ready_probe_dispatcher
    )

    response =
      conn
      |> get("/ready")
      |> json_response(503)

    assert response == %{
             "status" => "error",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "error"
             }
           }

    public_output = inspect(response)
    refute public_output =~ "#PID"
    refute public_output =~ "missing_ready_probe_dispatcher"
    refute public_output =~ "migration"
    refute public_output =~ "http"
    refute public_output =~ "secret"
  end

  test "GET /ready requires an enabled dispatcher's attempt supervisor", %{conn: conn} do
    name = :ready_probe_dispatcher_missing_attempt_supervisor

    start_supervised!(
      {WebhookDispatcher,
       enabled: true,
       dispatch_on_start?: false,
       interval_ms: 60_000,
       name: name,
       attempt_supervisor: WebhookDispatcher.AttemptSupervisor}
    )

    Application.put_env(:atp, WebhookDispatcher,
      enabled: true,
      name: name,
      attempt_supervisor: :missing_ready_probe_attempt_supervisor
    )

    response =
      conn
      |> get("/ready")
      |> json_response(503)

    assert response == %{
             "status" => "error",
             "checks" => %{
               "database" => "ok",
               "transport_runtime" => "ok",
               "webhook_dispatcher" => "error"
             }
           }

    public_output = inspect(response)
    refute public_output =~ "ready_probe_dispatcher_missing_attempt_supervisor"
    refute public_output =~ "missing_ready_probe_attempt_supervisor"
  end
end
