defmodule Atp.A2AMessageTest do
  use ExUnit.Case, async: true

  alias Atp.Transport.A2A.Message

  test "validates minimal and rich A2A Message payloads" do
    minimal = %{
      "messageId" => "client-msg-1",
      "role" => "ROLE_USER",
      "parts" => [%{"text" => "hello"}]
    }

    rich = %{
      "messageId" => "agent-msg-1",
      "role" => "ROLE_AGENT",
      "contextId" => "ctx_123",
      "taskId" => "task_123",
      "extensions" => ["https://example.test/a2a/ext"],
      "referenceTaskIds" => ["task_001"],
      "metadata" => %{"trace_id" => "trace_123"},
      "parts" => [
        %{"text" => "done", "metadata" => %{"format" => "plain"}},
        %{"data" => [1, true, nil, %{"ok" => true}]},
        %{"url" => "https://example.test/artifact.json", "mediaType" => "application/json"},
        %{"raw" => "aGVsbG8=", "filename" => "hello.txt", "mediaType" => "text/plain"}
      ]
    }

    assert Message.content_type() == "application/a2a+json"
    assert Message.version() == "1.0"
    assert Message.validate(minimal) == {:ok, minimal}
    assert Message.validate(rich) == {:ok, rich}
  end

  test "rejects invalid A2A Message payloads" do
    invalid_messages = [
      "not an object",
      %{"role" => "ROLE_USER", "parts" => [%{"text" => "missing id"}]},
      %{"messageId" => " ", "role" => "ROLE_USER", "parts" => [%{"text" => "blank id"}]},
      %{"messageId" => "msg_1", "role" => "user", "parts" => [%{"text" => "legacy role"}]},
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_AGENT",
        "parts" => [%{"text" => "missing context"}]
      },
      %{"messageId" => "msg_1", "role" => "ROLE_USER"},
      %{"messageId" => "msg_1", "role" => "ROLE_USER", "parts" => []},
      %{"messageId" => "msg_1", "role" => "ROLE_USER", "parts" => ["not a part"]},
      %{"messageId" => "msg_1", "role" => "ROLE_USER", "parts" => [%{"metadata" => %{}}]},
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"text" => "too much", "data" => %{}}]
      },
      %{"messageId" => "msg_1", "role" => "ROLE_USER", "parts" => [%{"text" => 123}]},
      %{"messageId" => "msg_1", "role" => "ROLE_USER", "parts" => [%{"raw" => 123}]},
      %{"messageId" => "msg_1", "role" => "ROLE_USER", "parts" => [%{"url" => 123}]},
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}}],
        "metadata" => []
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}}],
        "contextId" => 123
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}}],
        "taskId" => " "
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}}],
        "extensions" => "not a list"
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}}],
        "extensions" => [123]
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}}],
        "referenceTaskIds" => [" "]
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}, "metadata" => []}]
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}, "filename" => 123}]
      },
      %{
        "messageId" => "msg_1",
        "role" => "ROLE_USER",
        "parts" => [%{"data" => %{}, "mediaType" => " "}]
      }
    ]

    for invalid <- invalid_messages do
      assert Message.validate(invalid) == {:error, :invalid_a2a_message}
    end
  end
end
