defmodule AtpWeb.APIResponseTest do
  use Atp.ConnCase, async: true

  alias AtpWeb.{APIResponse, ErrorJSON}

  test "renders explicit and fallback API errors", %{conn: conn} do
    success =
      {:ok, 200, %{"ok" => true}}
      |> APIResponse.send_result(build_conn())
      |> json_response(200)

    assert success == %{"ok" => true}

    conflict =
      {:error, :idempotency_conflict}
      |> APIResponse.send_result(conn, %{idempotency_conflict: :conflict})
      |> json_response(409)

    assert error_code(conflict) == "idempotency_conflict"

    fallback =
      {:error, {:unexpected, :shape}}
      |> APIResponse.send_result(build_conn(), %{})
      |> json_response(422)

    assert error_code(fallback) == "invalid_request"

    assert APIResponse.error_body("new_error") == %{
             "error" => %{
               "code" => "new_error",
               "message" => "The request could not be completed."
             }
           }
  end

  test "renders Phoenix error templates through the API envelope" do
    assert ErrorJSON.render("404.json", %{}) == APIResponse.error_body(:not_found)
    assert ErrorJSON.render("500.json", %{}) == APIResponse.error_body(:unexpected_error)
    assert ErrorJSON.render("other.json", %{}) == APIResponse.error_body(:unexpected_error)
  end
end
