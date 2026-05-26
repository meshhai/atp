defmodule Atp.Transport.JsonValueTest do
  use ExUnit.Case, async: true

  alias Atp.Transport.JsonValue

  test "casts all JSON scalar and nested values" do
    assert JsonValue.cast(nil) == {:ok, nil}
    assert JsonValue.cast(true) == {:ok, true}
    assert JsonValue.cast("text") == {:ok, "text"}
    assert JsonValue.cast(42) == {:ok, 42}
    assert JsonValue.cast(1.5) == {:ok, 1.5}

    nested = %{"items" => [nil, true, "text", 42, 1.5, %{"ok" => false}]}

    assert JsonValue.cast(nested) == {:ok, nested}
    assert JsonValue.dump(nested) == {:ok, nested}
    assert JsonValue.load(nested) == {:ok, nested}
  end

  test "rejects values that cannot be represented as JSON" do
    assert JsonValue.cast(%{atom_key: "not allowed"}) == :error
    assert JsonValue.cast(["ok", {:tuple, "not allowed"}]) == :error
    assert JsonValue.cast(self()) == :error
  end
end
