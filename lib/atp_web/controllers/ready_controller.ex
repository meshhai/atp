defmodule AtpWeb.ReadyController do
  use AtpWeb, :controller

  alias Atp.Readiness

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    result = Readiness.check()

    conn
    |> put_status(http_status(result))
    |> json(result)
  end

  defp http_status(%{"status" => "ok"}), do: :ok
  defp http_status(_result), do: :service_unavailable
end
