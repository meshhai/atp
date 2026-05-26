defmodule AtpWeb.ErrorJSON do
  @moduledoc false

  alias AtpWeb.APIResponse

  @spec render(String.t(), map()) :: map()
  def render("400.json", _assigns), do: APIResponse.error_body(:invalid_request)
  def render("404.json", _assigns), do: APIResponse.error_body(:not_found)
  def render("500.json", _assigns), do: APIResponse.error_body(:unexpected_error)
  def render(_template, _assigns), do: APIResponse.error_body(:unexpected_error)
end
