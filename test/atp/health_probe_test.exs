defmodule Atp.HealthProbeTest do
  use Atp.ConnCase, async: true

  test "GET /health returns minimal public liveness JSON", %{conn: conn} do
    response =
      conn
      |> get("/health")
      |> json_response(200)

    assert response == %{"status" => "ok"}
  end
end
