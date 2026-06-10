defmodule Atp.CLI do
  @moduledoc """
  Command-line edge adapter for ATP.

  The CLI stores local alias metadata and tokens on disk, then uses the public
  HTTP API as its carrier boundary.
  """

  @account_name "ATP CLI Account"
  @default_server_url "http://localhost:4000"
  @default_lease_seconds 60

  @type alias_metadata :: %{
          required(String.t()) => String.t()
        }

  @type agent_credentials :: %{
          required(String.t()) => String.t()
        }

  @type config :: %{
          server_url: String.t(),
          active_alias: String.t() | nil,
          aliases: %{String.t() => alias_metadata()}
        }

  @type credentials :: %{
          account_id: String.t() | nil,
          account_key_id: String.t() | nil,
          account_token: String.t() | nil,
          agents: %{String.t() => agent_credentials()}
        }

  @spec main([String.t()]) :: no_return()
  def main(args), do: args |> run() |> System.halt()

  @spec run([String.t()]) :: non_neg_integer()
  def run(args) when is_list(args) do
    case dispatch(args) do
      {:ok, output} ->
        IO.write(output)
        0

      {:error, reason} ->
        IO.puts(:stderr, "error: #{reason}")
        1
    end
  end

  defp dispatch(["init"]), do: init(@default_server_url)
  defp dispatch(["init", "--server", server_url]), do: init(server_url)
  defp dispatch(["agent", "create", alias]), do: create_agent(alias)
  defp dispatch(["agent", "list"]), do: list_agents()
  defp dispatch(["use", alias]), do: use_alias(alias)
  defp dispatch(["whoami"]), do: whoami()
  defp dispatch(["send", recipient, text]), do: send_message(recipient, text, nil)

  defp dispatch(["send", recipient, text, "--as", alias]),
    do: send_message(recipient, text, alias)

  defp dispatch(["send", "--as", alias, recipient, text]),
    do: send_message(recipient, text, alias)

  defp dispatch(["message", "status", message_id]), do: message_status(message_id, nil)

  defp dispatch(["message", "status", message_id, "--as", alias]),
    do: message_status(message_id, alias)

  defp dispatch(["message", "status", "--as", alias, message_id]),
    do: message_status(message_id, alias)

  defp dispatch(["inbox"]), do: claim_inbox(nil)
  defp dispatch(["inbox", "--as", alias]), do: claim_inbox(alias)
  defp dispatch(["--as", alias, "inbox"]), do: claim_inbox(alias)

  defp dispatch(["ack", delivery_id, "--completed", text]),
    do: complete_delivery(delivery_id, text, nil)

  defp dispatch(["ack", delivery_id, "--completed", text, "--as", alias]),
    do: complete_delivery(delivery_id, text, alias)

  defp dispatch(["ack", "--as", alias, delivery_id, "--completed", text]),
    do: complete_delivery(delivery_id, text, alias)

  defp dispatch(["session", "open", recipient, text]), do: open_session(recipient, text, nil)

  defp dispatch(["session", "open", recipient, text, "--as", alias]),
    do: open_session(recipient, text, alias)

  defp dispatch(["session", "open", "--as", alias, recipient, text]),
    do: open_session(recipient, text, alias)

  defp dispatch(["session", "accept", session_id]), do: accept_session(session_id, nil)

  defp dispatch(["session", "accept", session_id, "--as", alias]),
    do: accept_session(session_id, alias)

  defp dispatch(["session", "accept", "--as", alias, session_id]),
    do: accept_session(session_id, alias)

  defp dispatch(["session", "reject", session_id, reason]),
    do: reject_session(session_id, reason, nil)

  defp dispatch(["session", "reject", session_id, reason, "--as", alias]),
    do: reject_session(session_id, reason, alias)

  defp dispatch(["session", "reject", "--as", alias, session_id, reason]),
    do: reject_session(session_id, reason, alias)

  defp dispatch(["session", "send", session_id, text]),
    do: send_session_message(session_id, text, nil)

  defp dispatch(["session", "send", session_id, text, "--as", alias]),
    do: send_session_message(session_id, text, alias)

  defp dispatch(["session", "send", "--as", alias, session_id, text]),
    do: send_session_message(session_id, text, alias)

  defp dispatch(["session", "show", session_id]), do: show_session(session_id, nil)

  defp dispatch(["session", "show", session_id, "--as", alias]),
    do: show_session(session_id, alias)

  defp dispatch(["session", "show", "--as", alias, session_id]),
    do: show_session(session_id, alias)

  defp dispatch(["session", "watch", session_id]), do: watch_session(session_id, nil)

  defp dispatch(["session", "watch", session_id, "--as", alias]),
    do: watch_session(session_id, alias)

  defp dispatch(["session", "watch", "--as", alias, session_id]),
    do: watch_session(session_id, alias)

  defp dispatch(["help"]), do: {:ok, help()}
  defp dispatch(["--help"]), do: {:ok, help()}
  defp dispatch(_args), do: {:error, "unknown command. Run `atp help`."}

  defp init(server_url) do
    server_url = normalize_server_url(server_url)

    with :ok <- ensure_home(),
         {:ok, account} <- post(server_url, "/api/accounts", %{"name" => @account_name}) do
      config = %{server_url: server_url, active_alias: nil, aliases: %{}}

      credentials = %{
        account_id: account["id"],
        account_key_id: get_in(account, ["account_api_key", "id"]),
        account_token: get_in(account, ["account_api_key", "token"]),
        agents: %{}
      }

      with :ok <- write_config(config),
           :ok <- write_credentials(credentials) do
        {:ok,
         """
         ATP account initialized.
         Server: #{server_url}
         Account: #{account["id"]}
         Config: #{config_path()}
         Credentials: #{credentials_path()}

         No default agent was created.
         Next: atp agent create <alias>
         """}
      end
    end
  end

  defp create_agent(alias) do
    with :ok <- validate_alias(alias),
         {:ok, config} <- read_config(),
         {:ok, credentials} <- read_credentials(),
         {:ok, account_token} <- fetch_account_token(credentials),
         {:ok, agent} <- register_agent(config.server_url, account_token, alias) do
      updated_config = put_agent_alias(config, alias, agent)
      updated_credentials = put_agent_credentials(credentials, alias, agent)

      with :ok <- write_config(updated_config),
           :ok <- write_credentials(updated_credentials) do
        {:ok, agent_created_output(alias, agent)}
      end
    end
  end

  defp list_agents do
    with {:ok, config} <- read_config() do
      rows =
        config.aliases
        |> Enum.sort_by(fn {alias, _metadata} -> alias end)
        |> Enum.map(fn {alias, metadata} -> "#{alias}\t#{metadata["address"]}" end)

      output =
        case rows do
          [] -> "No local agents registered.\n"
          rows -> Enum.join(["Alias\tAddress" | rows], "\n") <> "\n"
        end

      {:ok, output}
    end
  end

  defp use_alias(alias) do
    with {:ok, config} <- read_config(),
         {:ok, metadata} <- fetch_alias(config, alias),
         :ok <- config |> Map.put(:active_alias, alias) |> write_config() do
      {:ok,
       """
       Active alias: #{alias}
       Address: #{metadata["address"]}
       """}
    end
  end

  defp whoami do
    with {:ok, config} <- read_config(),
         {:ok, alias} <- active_alias(config),
         {:ok, metadata} <- fetch_alias(config, alias) do
      {:ok,
       """
       Alias: #{alias}
       Address: #{metadata["address"]}
       """}
    end
  end

  defp send_message(recipient_input, text, alias_override) do
    with {:ok, config, sender_alias, sender_metadata, sender_token} <-
           agent_context(alias_override),
         {:ok, recipient} <- resolve_recipient(config, recipient_input),
         {:ok, body} <-
           post(
             config.server_url,
             "/api/messages",
             %{
               "to" => recipient.address,
               "payload" => user_text_payload(text)
             },
             agent_headers(sender_token, "cli-send")
           ) do
      {:ok, send_output(sender_alias, sender_metadata, recipient, body)}
    end
  end

  defp message_status(message_id, alias_override) do
    with {:ok, config, token} <- session_read_context(alias_override),
         {:ok, body} <-
           get(
             config.server_url,
             "/api/messages/#{message_id}",
             authorization_headers(token)
           ) do
      {:ok, message_status_output(config, body)}
    end
  end

  defp claim_inbox(alias_override) do
    with {:ok, config, _alias, _metadata, token} <- agent_context(alias_override),
         {:ok, body} <-
           post(
             config.server_url,
             "/api/inbox/claims",
             %{"lease_seconds" => @default_lease_seconds},
             agent_headers(token, "cli-inbox")
           ) do
      case claimed_delivery(body) do
        nil -> {:ok, "No pending deliveries.\n"}
        delivery -> {:ok, inbox_output(config, delivery)}
      end
    end
  end

  defp complete_delivery(delivery_id, text, alias_override) do
    with {:ok, config, _alias, _metadata, token} <- agent_context(alias_override),
         {:ok, body} <-
           post(
             config.server_url,
             "/api/deliveries/#{delivery_id}/acks",
             %{
               "status" => "completed",
               "payload" => agent_text_payload(text)
             },
             agent_headers(token, "cli-ack")
           ) do
      {:ok, ack_output(delivery_id, body)}
    end
  end

  defp open_session(recipient_input, text, alias_override) do
    with {:ok, config, sender_alias, sender_metadata, sender_token} <-
           agent_context(alias_override),
         {:ok, recipient} <- resolve_recipient(config, recipient_input),
         {:ok, body} <-
           post(
             config.server_url,
             "/api/sessions",
             %{
               "to" => recipient.address,
               "payload" => user_text_payload(text)
             },
             agent_headers(sender_token, "cli-session-open")
           ) do
      {:ok, session_open_output(sender_alias, sender_metadata, recipient, body)}
    end
  end

  defp accept_session(session_id, alias_override) do
    with {:ok, body} <- post_session_action(session_id, "accept", %{}, alias_override) do
      {:ok, session_ack_output("accepted", session_id, body)}
    end
  end

  defp reject_session(session_id, reason, alias_override) do
    body = %{"payload" => agent_text_payload(reason, session_reject_message_id(session_id))}

    with {:ok, body} <- post_session_action(session_id, "reject", body, alias_override) do
      {:ok, session_ack_output("rejected", session_id, body)}
    end
  end

  defp send_session_message(session_id, text, alias_override) do
    with {:ok, config, _alias, _metadata, token} <- agent_context(alias_override),
         {:ok, body} <-
           post(
             config.server_url,
             "/api/sessions/#{session_id}/messages",
             %{"payload" => user_text_payload(text)},
             agent_headers(token, "cli-session-send")
           ) do
      {:ok, session_message_output(session_id, body)}
    end
  end

  defp show_session(session_id, alias_override) do
    with {:ok, config, token} <- session_read_context(alias_override),
         {:ok, body} <-
           get(
             config.server_url,
             "/api/sessions/#{session_id}",
             authorization_headers(token)
           ) do
      {:ok, session_show_output(config, body)}
    end
  end

  defp watch_session(session_id, alias_override) do
    with {:ok, config, token} <- session_read_context(alias_override) do
      case poll_session_watch(
             config,
             token,
             session_id,
             MapSet.new(),
             false,
             0,
             watch_max_polls()
           ) do
        :ok -> {:ok, ""}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp post_session_action(session_id, action, body, alias_override) do
    with {:ok, config, _alias, _metadata, token} <- agent_context(alias_override) do
      post(
        config.server_url,
        "/api/sessions/#{session_id}/#{action}",
        body,
        agent_headers_with_idempotency_key(
          token,
          session_action_idempotency_key(action, session_id)
        )
      )
    end
  end

  defp session_read_context(alias_override) do
    with {:ok, config, _alias, _metadata, token} <- agent_context(alias_override) do
      {:ok, config, token}
    end
  end

  defp agent_context(alias_override) do
    with {:ok, config} <- read_config(),
         {:ok, credentials} <- read_credentials(),
         {:ok, alias} <- selected_alias(config, alias_override),
         {:ok, _metadata} <- fetch_alias(config, alias),
         {:ok, token} <- fetch_agent_token(credentials, alias) do
      {:ok, config, alias, config.aliases[alias], token}
    end
  end

  defp register_agent(server_url, account_token, alias) do
    headers = [
      {"authorization", "Bearer #{account_token}"},
      {"idempotency-key", "cli-agent-create-#{alias}"}
    ]

    post(
      server_url,
      "/api/agents",
      %{
        "display_name" => alias,
        "description" => "ATP CLI local alias #{alias}"
      },
      headers
    )
  end

  defp post(server_url, path, body, headers \\ []) do
    request(
      method: :post,
      url: endpoint_url(server_url, path),
      json: body,
      headers: headers,
      retry: false
    )
  end

  defp get(server_url, path, headers) do
    request(
      method: :get,
      url: endpoint_url(server_url, path),
      headers: headers,
      retry: false
    )
  end

  defp request(options) do
    {:ok, _started} = Application.ensure_all_started(:req)

    options = Keyword.merge(options, req_options())

    case Req.request(options) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, api_error(status, response_body)}

      {:error, reason} ->
        {:error, Exception.message(reason)}
    end
  end

  defp api_error(status, %{"error" => %{"code" => code, "message" => message}}) do
    "server returned #{status} #{code}: #{message}"
  end

  defp api_error(status, _body), do: "server returned #{status}"

  defp put_agent_alias(config, alias, agent) do
    metadata = %{
      "agent_id" => agent["id"],
      "address" => agent["address"]
    }

    update_in(config.aliases, &Map.put(&1, alias, metadata))
  end

  defp put_agent_credentials(credentials, alias, agent) do
    agent_credentials = %{
      "agent_key_id" => get_in(agent, ["agent_api_key", "id"]),
      "agent_token" => get_in(agent, ["agent_api_key", "token"])
    }

    update_in(credentials.agents, &Map.put(&1, alias, agent_credentials))
  end

  defp agent_created_output(alias, agent) do
    """
    Registered ATP agent.
    Alias: #{alias}
    Address: #{agent["address"]}
    Credentials: #{credentials_path()} (token stored locally, not printed)

    Paste this into the agent session:

    You are using ATP through the local CLI as alias #{alias}.
    Your ATP address is #{agent["address"]}.
    Run `atp use #{alias}` before sending or claiming ATP messages.
    Verify the active identity with `atp whoami`.
    Do not ask for ATP tokens; credentials are already stored locally at #{credentials_path()}.
    """ <> "\n"
  end

  defp help do
    """
    Usage:
      atp init [--server URL]
      atp agent create <alias>
      atp agent list
      atp use <alias>
      atp whoami
      atp send <alias-or-address> "<text>" [--as <alias>]
      atp message status <message-id> [--as <alias>]
      atp inbox [--as <alias>]
      atp ack <delivery-id> --completed "<text>" [--as <alias>]
      atp session open <alias-or-address> "<text>" [--as <alias>]
      atp session accept <session-id> [--as <alias>]
      atp session reject <session-id> "<reason>" [--as <alias>]
      atp session send <session-id> "<text>" [--as <alias>]
      atp session show <session-id> [--as <alias>]
      atp session watch <session-id> [--as <alias>]
    """
  end

  defp fetch_account_token(%{account_token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp fetch_account_token(_credentials), do: {:error, "run `atp init` before creating agents"}

  defp fetch_agent_token(%{agents: agents}, alias) do
    case get_in(agents, [alias, "agent_token"]) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _missing ->
        {:error, "no stored credentials for alias #{alias}. Run `atp agent create #{alias}`."}
    end
  end

  defp fetch_alias(%{aliases: aliases}, alias) do
    case Map.fetch(aliases, alias) do
      {:ok, metadata} -> {:ok, metadata}
      :error -> {:error, "unknown alias #{alias}"}
    end
  end

  defp active_alias(%{active_alias: alias}) when is_binary(alias) and alias != "",
    do: {:ok, alias}

  defp active_alias(_config), do: {:error, "no active alias. Run `atp use <alias>`."}

  defp selected_alias(config, nil), do: active_alias(config)
  defp selected_alias(_config, alias), do: {:ok, alias}

  defp resolve_recipient(%{aliases: aliases}, recipient_input) do
    recipient_input = String.trim(recipient_input)

    cond do
      Map.has_key?(aliases, recipient_input) ->
        {:ok,
         %{
           input: recipient_input,
           alias: recipient_input,
           address: get_in(aliases, [recipient_input, "address"])
         }}

      String.starts_with?(recipient_input, "atp://agent/") ->
        {:ok, %{input: recipient_input, alias: nil, address: recipient_input}}

      true ->
        {:error,
         "unknown recipient #{recipient_input}. Use a local alias or atp://agent/... address."}
    end
  end

  defp user_text_payload(text), do: text_payload("ROLE_USER", text)

  defp agent_text_payload(text), do: agent_text_payload(text, cli_message_id())

  defp agent_text_payload(text, message_id) do
    "ROLE_AGENT"
    |> text_payload(text, message_id)
    |> Map.put("contextId", "ctx_#{message_id}")
  end

  defp text_payload(role, text), do: text_payload(role, text, cli_message_id())

  defp text_payload(role, text, message_id) do
    %{
      "messageId" => message_id,
      "role" => role,
      "parts" => [%{"text" => text}]
    }
  end

  defp agent_headers(token, idempotency_prefix) do
    agent_headers_with_idempotency_key(token, unique_key(idempotency_prefix))
  end

  defp authorization_headers(token), do: [{"authorization", "Bearer #{token}"}]

  defp agent_headers_with_idempotency_key(token, idempotency_key) do
    [
      {"authorization", "Bearer #{token}"},
      {"idempotency-key", idempotency_key}
    ]
  end

  defp session_action_idempotency_key(action, session_id) do
    "cli-session-#{action}-#{session_id}"
  end

  defp session_reject_message_id(session_id), do: "cli-msg-session-reject-#{session_id}"

  defp unique_key(prefix), do: "#{prefix}-#{unique_suffix()}"
  defp cli_message_id, do: unique_key("cli-msg")

  defp unique_suffix do
    "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp send_output(sender_alias, sender_metadata, recipient, body) do
    """
    Message sent.
    Sender: #{format_alias_address(sender_alias, sender_metadata["address"])}
    Recipient: #{recipient.input}
    #{resolved_address_line(recipient)}
    Message: #{get_in(body, ["message", "id"])}
    #{send_delivery_line(body)}
    """
  end

  defp send_delivery_line(body) do
    case first_delivery_id(body) do
      nil -> "Delivery: none yet (polling recipient should run `atp inbox`)"
      delivery_id -> "Delivery: #{delivery_id}"
    end
  end

  defp resolved_address_line(%{alias: nil, address: address}), do: "Recipient address: #{address}"
  defp resolved_address_line(%{address: address}), do: "Resolved address: #{address}"

  defp first_delivery_id(%{"deliveries" => deliveries}) when is_list(deliveries) do
    Enum.find_value(deliveries, fn delivery -> delivery["id"] end)
  end

  defp first_delivery_id(%{"message_status" => message_status}) when is_map(message_status) do
    first_delivery_id(message_status)
  end

  defp first_delivery_id(_body), do: nil

  defp message_status_output(config, body) do
    message = Map.get(body, "message", %{})

    [
      "Message status.",
      "Message: #{status_field(message["id"])}",
      "Sender: #{status_address(config, message["from"])}",
      "Recipient: #{status_address(config, message["to"])}",
      "Created: #{status_field(message["created_at"])}",
      "Carrier status: #{status_field(body["carrier_status"])}",
      "ACK status: #{status_field(body["ack_status"])}",
      "Terminal: #{status_field(body["terminal_at"])}",
      "",
      message_deliveries_output(Map.get(body, "deliveries", []))
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp message_deliveries_output(deliveries) when is_list(deliveries) do
    case deliveries do
      [] ->
        "Deliveries: none"

      deliveries ->
        deliveries
        |> Enum.map(&delivery_status_output/1)
        |> then(&Enum.join(["Deliveries:" | &1], "\n"))
    end
  end

  defp message_deliveries_output(_deliveries), do: "Deliveries: none"

  defp delivery_status_output(delivery) when is_map(delivery) do
    [
      "- Delivery: #{status_field(delivery["id"])}",
      "  Mode: #{status_field(delivery["mode"])}",
      "  Status: #{status_field(delivery["status"])}",
      "  Attempt count: #{delivery_attempt_count(delivery)}",
      "  Claimed: #{status_field(delivery["claimed_at"])}",
      "  Lease until: #{status_field(delivery["leased_until"])}",
      "  Next retry: #{status_field(delivery["next_attempt_at"])}",
      "  Delivered: #{status_field(delivery["delivered_at"])}"
    ]
    |> maybe_append_last_error(delivery)
    |> Kernel.++(webhook_attempt_lines(Map.get(delivery, "attempts", [])))
    |> Enum.join("\n")
  end

  defp delivery_status_output(_delivery), do: "- Delivery: -"

  defp delivery_attempt_count(%{"attempt_count" => count, "max_attempts" => max_attempts})
       when not is_nil(max_attempts) do
    "#{status_field(count)}/#{status_field(max_attempts)}"
  end

  defp delivery_attempt_count(%{"attempt_count" => count}), do: status_field(count)
  defp delivery_attempt_count(_delivery), do: "-"

  defp maybe_append_last_error(lines, %{"last_error" => error}) do
    case status_error_field(error) do
      "-" -> lines
      error -> lines ++ ["  Last error: #{error}"]
    end
  end

  defp maybe_append_last_error(lines, _delivery), do: lines

  defp webhook_attempt_lines(attempts) when is_list(attempts) do
    case attempts do
      [] ->
        ["  Webhook attempts: none"]

      attempts ->
        ["  Webhook attempts:" | Enum.flat_map(attempts, &webhook_attempt_output/1)]
    end
  end

  defp webhook_attempt_lines(_attempts), do: ["  Webhook attempts: none"]

  defp webhook_attempt_output(attempt) when is_map(attempt) do
    [
      "  - Attempt ##{status_field(attempt["attempt_number"])}: #{status_field(attempt["result"])}",
      "    Response: #{status_field(attempt["response_status"])}",
      "    Error: #{status_error_field(attempt["error"])}",
      "    Retry: #{status_field(attempt["next_attempt_at"])}",
      "    Created: #{status_field(attempt["created_at"])}"
    ]
  end

  defp webhook_attempt_output(_attempt), do: ["  - Attempt #-: -"]

  defp status_address(config, address) when is_binary(address),
    do: format_address(config, address)

  defp status_address(_config, _address), do: "-"

  defp status_field(nil), do: "-"

  defp status_field(value) when is_binary(value) do
    value
    |> String.replace(~r/[\t\r\n]+/, " ")
    |> String.trim()
    |> blank_status_field()
  end

  defp status_field(value), do: value |> to_string() |> status_field()

  defp status_error_field(value) do
    value
    |> status_field()
    |> redact_status_error()
  end

  defp blank_status_field(""), do: "-"
  defp blank_status_field(value), do: value

  defp redact_status_error("-"), do: "-"

  defp redact_status_error(value) do
    if Regex.match?(
         ~r/(token|secret|signature|authorization|bearer|whsec_|raw body|request body)/i,
         value
       ) do
      "internal_error"
    else
      value
    end
  end

  defp claimed_delivery(%{"delivery" => nil}), do: nil
  defp claimed_delivery(%{"delivery" => delivery}) when is_map(delivery), do: delivery
  defp claimed_delivery(%{"id" => _id} = delivery), do: delivery

  defp inbox_output(config, %{"message" => message} = delivery) do
    """
    Delivery: #{delivery["id"]}
    Sender: #{format_address(config, message["from"])}
    Message: #{message["id"]}
    Timestamp: #{message["created_at"]}
    Text: #{message_text_preview(message)}
    """
  end

  defp ack_output(delivery_id, body) do
    ack = Map.get(body, "ack", %{})

    """
    ACK completed.
    Delivery: #{ack["delivery_id"] || delivery_id}
    Message: #{ack["message_id"] || get_in(body, ["message_status", "message", "id"])}
    ACK: #{ack["id"]}
    """
  end

  defp session_open_output(sender_alias, sender_metadata, recipient, body) do
    session = Map.get(body, "session", %{})
    message = get_in(body, ["message_status", "message"]) || %{}

    """
    Session opened.
    Sender: #{format_alias_address(sender_alias, sender_metadata["address"])}
    Recipient: #{recipient.input}
    #{resolved_address_line(recipient)}
    Session: #{session["id"]}
    Status: #{session["status"]}
    Opening message: #{session["opening_message_id"] || message["id"]}
    Opening delivery: #{first_delivery_id(body) || "none"}
    """
  end

  defp session_ack_output(status, session_id, body) do
    session = Map.get(body, "session", %{})
    ack = Map.get(body, "ack", %{})

    """
    Session #{status}.
    Session: #{session["id"] || session_id}
    Status: #{session["status"]}
    Opening delivery: #{ack["delivery_id"] || "none"}
    ACK: #{ack["id"]}
    """
  end

  defp session_message_output(session_id, body) do
    session = Map.get(body, "session", %{})
    message = get_in(body, ["message_status", "message"]) || %{}

    """
    Session message sent.
    Session: #{session["id"] || session_id}
    Sequence: #{message["session_sequence"] || session["last_sequence"]}
    Message: #{message["id"]}
    Delivery: #{first_delivery_id(body) || "none"}
    """
  end

  defp session_show_output(config, body) do
    session = Map.get(body, "session", %{})
    messages = transcript_messages(body)

    """
    Session: #{session["id"]}
    Status: #{session["status"]}
    Initiator: #{format_address(config, session["initiator"])}
    Recipient: #{format_address(config, session["recipient"])}
    Last sequence: #{session["last_sequence"]}

    #{session_transcript_table(config, messages)}
    """
  end

  defp session_transcript_table(_config, []), do: "No session messages.\n"

  defp session_transcript_table(config, messages) do
    messages = Enum.sort_by(messages, &message_sort_key/1)
    widths = session_table_widths(config, messages)

    session_table_header(widths) <> format_session_rows(config, messages, widths)
  end

  @session_table_default_widths %{seq: 3, time: 4, sender: 6, recipient: 9, status: 6}
  @session_table_max_widths %{seq: 6, time: 30, sender: 24, recipient: 24, status: 12}
  @session_message_width 120

  defp session_table_header(widths) do
    [
      pad_table_cell("Seq", :seq, widths),
      pad_table_cell("Time", :time, widths),
      pad_table_cell("Sender", :sender, widths),
      pad_table_cell("Recipient", :recipient, widths),
      pad_table_cell("Status", :status, widths),
      "Message"
    ]
    |> Enum.join("  ")
    |> Kernel.<>("\n")
  end

  defp session_table_widths(config, messages) do
    config
    |> known_aliases()
    |> Enum.reduce(@session_table_default_widths, fn alias, widths ->
      widths
      |> widen_table_column(:sender, alias)
      |> widen_table_column(:recipient, alias)
    end)
    |> then(fn widths ->
      Enum.reduce(messages, widths, fn message_status, widths ->
        message = Map.get(message_status, "message", %{})

        widths
        |> widen_table_column(:seq, message["session_sequence"])
        |> widen_table_column(:time, message["created_at"])
        |> widen_table_column(:sender, table_address(config, message["from"]))
        |> widen_table_column(:recipient, table_address(config, message["to"]))
        |> widen_table_column(:status, transcript_status(message_status))
      end)
    end)
  end

  defp known_aliases(%{aliases: aliases}) when is_map(aliases), do: Map.keys(aliases)
  defp known_aliases(_config), do: []

  defp format_session_rows(config, messages, widths) do
    messages
    |> Enum.map_join("", &format_session_row(config, &1, widths))
  end

  defp format_session_row(config, message_status, widths) do
    message = Map.get(message_status, "message", %{})
    [first_message_line | continuation_lines] = wrapped_message_lines(message_text(message))

    first_line =
      [
        pad_table_cell(message["session_sequence"], :seq, widths),
        pad_table_cell(message["created_at"], :time, widths),
        pad_table_cell(table_address(config, message["from"]), :sender, widths),
        pad_table_cell(table_address(config, message["to"]), :recipient, widths),
        pad_table_cell(transcript_status(message_status), :status, widths),
        first_message_line
      ]
      |> Enum.join("  ")

    continuation_text =
      continuation_lines
      |> Enum.map_join("", &(session_message_indent(widths) <> &1 <> "\n"))

    first_line <> "\n" <> continuation_text
  end

  defp poll_session_watch(
         _config,
         _token,
         _session_id,
         _seen,
         _printed_header,
         poll_count,
         max_polls
       )
       when is_integer(max_polls) and poll_count >= max_polls do
    :ok
  end

  defp poll_session_watch(config, token, session_id, seen, printed_header, poll_count, max_polls) do
    case get(config.server_url, "/api/sessions/#{session_id}", authorization_headers(token)) do
      {:ok, body} ->
        messages =
          body
          |> transcript_messages()
          |> Enum.sort_by(&message_sort_key/1)

        widths = session_table_widths(config, messages)
        printed_header = print_watch_header_once(printed_header, widths)
        {new_messages, seen} = unseen_transcript_messages(messages, seen)
        IO.write(format_session_rows(config, new_messages, widths))

        next_poll_count = poll_count + 1

        if max_poll_reached?(next_poll_count, max_polls) do
          :ok
        else
          sleep_between_watch_polls()

          poll_session_watch(
            config,
            token,
            session_id,
            seen,
            printed_header,
            next_poll_count,
            max_polls
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_watch_header_once(true, _widths), do: true

  defp print_watch_header_once(false, widths) do
    IO.write(session_table_header(widths))
    true
  end

  defp unseen_transcript_messages(messages, seen) do
    messages
    |> Enum.reduce({[], seen}, fn message_status, {messages, seen} ->
      key = message_key(message_status)

      if MapSet.member?(seen, key) do
        {messages, seen}
      else
        {[message_status | messages], MapSet.put(seen, key)}
      end
    end)
    |> then(fn {messages, seen} -> {Enum.reverse(messages), seen} end)
  end

  defp transcript_messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp transcript_messages(_body), do: []

  defp message_sort_key(message_status) do
    message = Map.get(message_status, "message", %{})
    {message["session_sequence"] || 0, message["created_at"] || "", message["id"] || ""}
  end

  defp message_key(message_status) do
    message = Map.get(message_status, "message", %{})
    message["session_sequence"] || message["id"] || message_status
  end

  defp transcript_status(%{"ack_status" => status}) when is_binary(status) and status != "",
    do: status

  defp transcript_status(%{"carrier_status" => status}) when is_binary(status) and status != "",
    do: status

  defp transcript_status(_message_status), do: "-"

  defp table_address(config, address) when is_binary(address) do
    alias_for_address(config, address) || address
  end

  defp table_address(_config, _address), do: "-"

  defp table_cell(nil), do: "-"

  defp table_cell(value) do
    value
    |> to_string()
    |> String.replace(~r/[\t\r\n]+/, " ")
    |> String.trim()
  end

  defp widen_table_column(widths, column, value) do
    width =
      value
      |> table_cell()
      |> String.length()
      |> min(Map.fetch!(@session_table_max_widths, column))
      |> max(Map.fetch!(widths, column))

    Map.put(widths, column, width)
  end

  defp pad_table_cell(value, column, widths) do
    width = Map.fetch!(widths, column)

    value
    |> table_cell()
    |> truncate_table_cell(width)
    |> String.pad_trailing(width)
  end

  defp truncate_table_cell(value, width) do
    if String.length(value) <= width do
      value
    else
      String.slice(value, 0, width - 1) <> "~"
    end
  end

  defp session_message_indent(widths) do
    [:seq, :time, :sender, :recipient, :status]
    |> Enum.map(&Map.fetch!(widths, &1))
    |> Enum.map_join("  ", &String.duplicate(" ", &1))
    |> Kernel.<>("  ")
  end

  defp max_poll_reached?(poll_count, max_polls) when is_integer(max_polls),
    do: poll_count >= max_polls

  defp max_poll_reached?(_poll_count, _max_polls), do: false

  defp sleep_between_watch_polls do
    case watch_poll_interval_ms() do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 -> Process.sleep(interval_ms)
      _zero -> :ok
    end
  end

  defp format_address(config, address) do
    case alias_for_address(config, address) do
      nil -> address
      alias -> format_alias_address(alias, address)
    end
  end

  defp format_alias_address(alias, address), do: "#{alias} (#{address})"

  defp alias_for_address(%{aliases: aliases}, address) do
    Enum.find_value(aliases, fn {alias, metadata} ->
      if metadata["address"] == address, do: alias
    end)
  end

  defp message_text_preview(%{"payload" => %{"parts" => parts}}) when is_list(parts) do
    parts
    |> Enum.find_value("non-text payload", fn
      %{"text" => text} when is_binary(text) -> text
      _part -> nil
    end)
    |> normalize_message_text()
    |> String.slice(0, 120)
  end

  defp message_text_preview(_message), do: "non-text payload"

  defp message_text(%{"payload" => %{"parts" => parts}}) when is_list(parts) do
    parts
    |> Enum.find_value("non-text payload", fn
      %{"text" => text} when is_binary(text) -> text
      _part -> nil
    end)
    |> normalize_message_text()
  end

  defp message_text(_message), do: "non-text payload"

  defp normalize_message_text(text) do
    text
    |> String.replace(~r/[\t\r\n]+/, " ")
    |> String.replace(~r/ +/, " ")
    |> String.trim()
  end

  defp wrapped_message_lines(text) do
    text
    |> String.split(" ", trim: true)
    |> Enum.reduce([""], &append_wrapped_word/2)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> case do
      [] -> ["-"]
      lines -> lines
    end
  end

  defp append_wrapped_word(word, [""] = lines), do: [word | lines]

  defp append_wrapped_word(word, [line | rest]) do
    candidate = line <> " " <> word

    if String.length(candidate) <= @session_message_width do
      [candidate | rest]
    else
      [word, line | rest]
    end
  end

  defp validate_alias(alias) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, alias) do
      :ok
    else
      {:error, "alias must contain only letters, digits, dots, underscores, and hyphens"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure_home do
    case file_result(File.mkdir_p(atp_home()), "create", atp_home()) do
      :ok ->
        File.chmod(atp_home(), 0o700)
        |> file_result("set owner-only permissions on", atp_home())

      {:error, _reason} = error ->
        error
    end
  end

  defp read_config do
    with {:ok, content} <- read_file(config_path(), "run `atp init` first"),
         {:ok, parsed} <- parse_toml(content) do
      root = parsed.root

      {:ok,
       %{
         server_url: Map.get(root, "server_url", @default_server_url),
         active_alias: blank_to_nil(Map.get(root, "active_alias", "")),
         aliases: Map.get(parsed.tables, "aliases", %{})
       }}
    end
  end

  defp read_credentials do
    with {:ok, content} <- read_file(credentials_path(), "run `atp init` first"),
         {:ok, parsed} <- parse_toml(content) do
      root = parsed.root

      {:ok,
       %{
         account_id: root["account_id"],
         account_key_id: root["account_key_id"],
         account_token: root["account_token"],
         agents: Map.get(parsed.tables, "agents", %{})
       }}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path, missing_message) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, missing_message}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_config(config) do
    with :ok <- ensure_home() do
      config_path()
      |> File.write(render_config(config))
      |> file_result("write", config_path())
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_credentials(credentials) do
    with :ok <- ensure_home() do
      write_owner_only_file(credentials_path(), render_credentials(credentials))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp write_owner_only_file(path, content) do
    temporary_path = "#{path}.tmp-#{unique_suffix()}"

    result =
      with :ok <-
             file_result(File.write(temporary_path, "", [:exclusive]), "create", temporary_path),
           :ok <- set_owner_only_permissions(temporary_path),
           :ok <- file_result(File.write(temporary_path, content), "write", temporary_path) do
        File.rename(temporary_path, path)
        |> file_result("replace", path)
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        File.rm(temporary_path)
        error
    end
  end

  defp set_owner_only_permissions(path) do
    path
    |> credential_chmod(0o600)
    |> file_result("set owner-only permissions on", path)
  end

  defp render_config(config) do
    root = [
      ~s(server_url = "#{escape_value(config.server_url)}"),
      ~s(active_alias = "#{escape_value(config.active_alias || "")}")
    ]

    alias_tables =
      config.aliases
      |> Enum.sort_by(fn {alias, _metadata} -> alias end)
      |> Enum.flat_map(fn {alias, metadata} ->
        [
          "",
          ~s([aliases."#{escape_value(alias)}"]),
          ~s(agent_id = "#{escape_value(metadata["agent_id"])}"),
          ~s(address = "#{escape_value(metadata["address"])}")
        ]
      end)

    Enum.join(root ++ alias_tables, "\n") <> "\n"
  end

  defp render_credentials(credentials) do
    root = [
      ~s(account_id = "#{escape_value(credentials.account_id)}"),
      ~s(account_key_id = "#{escape_value(credentials.account_key_id)}"),
      ~s(account_token = "#{escape_value(credentials.account_token)}")
    ]

    agent_tables =
      credentials.agents
      |> Enum.sort_by(fn {alias, _metadata} -> alias end)
      |> Enum.flat_map(fn {alias, agent_credentials} ->
        [
          "",
          ~s([agents."#{escape_value(alias)}"]),
          ~s(agent_key_id = "#{escape_value(agent_credentials["agent_key_id"])}"),
          ~s(agent_token = "#{escape_value(agent_credentials["agent_token"])}")
        ]
      end)

    Enum.join(root ++ agent_tables, "\n") <> "\n"
  end

  defp parse_toml(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{root: %{}, tables: %{}}, :root}, fn {line, line_number},
                                                                     {:ok, parsed, section} ->
      parse_line(line, line_number, parsed, section)
    end)
    |> case do
      {:ok, parsed, _section} -> {:ok, parsed}
      {:error, _reason} = error -> error
    end
  end

  defp parse_line(line, line_number, parsed, section) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:cont, {:ok, parsed, section}}

      table = Regex.run(~r/^\[(aliases|agents)\."((?:\\"|[^"])*)"\]$/, trimmed) ->
        [_match, table_name, alias] = table
        {:cont, {:ok, parsed, {table_name, unescape_value(alias)}}}

      pair = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"(.*)"$/, trimmed) ->
        [_match, key, value] = pair
        {:cont, {:ok, put_parsed_value(parsed, section, key, unescape_value(value)), section}}

      true ->
        {:halt, {:error, "could not parse #{config_path()} line #{line_number}"}}
    end
  end

  defp put_parsed_value(parsed, :root, key, value) do
    put_in(parsed.root[key], value)
  end

  defp put_parsed_value(parsed, {table_name, alias}, key, value) do
    update_in(parsed.tables, fn tables ->
      update_in(tables, [Access.key(table_name, %{}), Access.key(alias, %{})], fn metadata ->
        Map.put(metadata, key, value)
      end)
    end)
  end

  defp escape_value(nil), do: ""

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp unescape_value(value) do
    value
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_server_url(server_url) do
    server_url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp endpoint_url(server_url, path), do: normalize_server_url(server_url) <> path

  defp config_path, do: Path.join(atp_home(), "config.toml")
  defp credentials_path, do: Path.join(atp_home(), "credentials.toml")

  defp atp_home do
    System.get_env("ATP_HOME") || Path.join(System.user_home!(), ".atp")
  end

  defp file_result(:ok, _action, _path), do: :ok

  defp file_result({:error, reason}, action, path) do
    {:error, "could not #{action} #{path}: #{:file.format_error(reason)}"}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp credential_chmod(path, mode) do
    chmod =
      :atp
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:credential_chmod, &File.chmod/2)

    chmod.(path, mode)
  end

  defp req_options do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp watch_poll_interval_ms do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:watch_poll_interval_ms, 1_000)
  end

  defp watch_max_polls do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:watch_max_polls, :infinity)
  end
end
