defmodule Atp.ParserErrorTest do
  use Atp.ConnCase, async: true

  alias AtpWeb.{APIResponse, ErrorJSON}

  test "Phoenix 400 errors render through the stable API envelope" do
    assert ErrorJSON.render("400.json", %{}) == APIResponse.error_body(:invalid_request)
  end

  test "malformed JSON requests render invalid_request instead of unexpected_error" do
    malformed =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/accounts", ~s({"name":))
      |> json_response(400)

    assert error_code(malformed) == "invalid_request"
  end
end
