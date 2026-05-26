defmodule Atp.DataCase do
  @moduledoc "Test case for ATP data-layer tests."

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Atp.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Atp.DataCase
    end
  end

  setup tags do
    Atp.DataCase.setup_sandbox(tags)
    :ok
  end

  alias Ecto.Adapters.SQL.Sandbox

  @spec setup_sandbox(map()) :: :ok
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Atp.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
