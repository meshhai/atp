defmodule Atp.Transport.WebhookDelivery do
  @moduledoc "Signed ATP webhook delivery and retry classification."

  import Ecto.Query

  alias Atp.Identity.{Account, Agent, ID, WebhookURL}
  alias Atp.Identity.WebhookURL.ConnectTarget
  alias Atp.Repo
  alias Atp.Transport.{Delivery, Message, MessageEnvelope, WebhookAttempt, WebhookSignature}

  @content_type "application/json"
  @free_attempts 3
  @basic_attempts 8
  @retry_delays_seconds [0, 30, 120, 300, 900, 3_600, 21_600, 86_400]
  @max_retry_delay_seconds 86_400
  @dispatch_lease_seconds 60
  @timeout_ms 10_000

  @type delivery_result :: {:ok, Message.t()} | {:error, term()}

  @spec prepare(Message.t(), Agent.t()) :: {:ok, Delivery.t()} | {:error, Ecto.Changeset.t()}
  def prepare(%Message{} = message, %Agent{} = recipient) do
    %Delivery{id: ID.generate("dlv")}
    |> Delivery.changeset(%{
      message_id: message.id,
      recipient_agent_id: recipient.id,
      mode: "webhook",
      status: "retry_scheduled",
      attempt_count: 0,
      max_attempts: max_attempts(recipient)
    })
    |> Repo.insert()
  end

  @spec deliver_now(String.t()) :: delivery_result()
  def deliver_now(delivery_id) when is_binary(delivery_id) do
    case acquire_webhook_delivery(delivery_id) do
      {:error, reason} -> {:error, reason}
      %Delivery{} = delivery -> deliver_prepared(delivery)
    end
  end

  @spec deliver_now(Message.t(), Agent.t()) :: delivery_result()
  def deliver_now(%Message{} = message, %Agent{} = recipient) do
    with {:ok, delivery} <- prepare(message, recipient) do
      deliver_now(delivery.id)
    end
  end

  @spec deliver_due(keyword()) :: {:ok, [delivery_result()]}
  def deliver_due(opts) do
    limit = Keyword.get(opts, :limit, 50)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    results =
      limit
      |> due_delivery_ids(now)
      |> Enum.map(&deliver_now/1)

    {:ok, results}
  end

  defp due_delivery_ids(limit, now) when is_integer(limit) and limit > 0 do
    {:ok, ids} =
      Repo.transaction(fn ->
        Delivery
        |> join(:inner, [delivery], message in assoc(delivery, :message), as: :message)
        |> where([delivery], delivery.mode == "webhook")
        |> where(^due_delivery_filter(now))
        |> where(^session_order_filter())
        |> order_by([delivery], asc: delivery.inserted_at)
        |> limit(^limit)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> select([delivery], delivery.id)
        |> Repo.all()
      end)

    ids
  end

  defp due_delivery_ids(_limit, _now), do: []

  defp due_delivery_filter(now) do
    dynamic(
      [delivery],
      (delivery.status == "retry_scheduled" and
         (is_nil(delivery.next_attempt_at) or delivery.next_attempt_at <= ^now)) or
        (delivery.status == "leased" and not is_nil(delivery.leased_until) and
           delivery.leased_until <= ^now)
    )
  end

  defp session_order_filter do
    dynamic(
      [message: message],
      is_nil(message.session_id) or is_nil(message.session_sequence) or
        not exists(
          from(prior_delivery in Delivery,
            join: prior_message in Message,
            on: prior_message.id == prior_delivery.message_id,
            where: prior_delivery.mode == "webhook",
            where: prior_delivery.status not in ["delivered", "failed"],
            where: prior_message.session_id == parent_as(:message).session_id,
            where: prior_message.session_sequence < parent_as(:message).session_sequence,
            select: 1
          )
        )
    )
  end

  defp acquire_webhook_delivery(delivery_id) do
    now = DateTime.utc_now(:microsecond)
    dispatch_lease_until = DateTime.add(now, @dispatch_lease_seconds, :second)

    {:ok, result} =
      Repo.transaction(fn ->
        case locked_webhook_delivery(delivery_id) do
          nil ->
            {:error, :not_found}

          %Delivery{status: status} = delivery when status in ["delivered", "failed"] ->
            delivery

          %Delivery{status: "leased", leased_until: %DateTime{} = leased_until} = delivery ->
            if DateTime.compare(leased_until, now) == :gt do
              {:error, :delivery_in_progress}
            else
              lease_delivery!(delivery, dispatch_lease_until)
            end

          %Delivery{} = delivery ->
            lease_delivery!(delivery, dispatch_lease_until)
        end
      end)

    result
  end

  defp locked_webhook_delivery(delivery_id) do
    Delivery
    |> where([delivery], delivery.id == ^delivery_id and delivery.mode == "webhook")
    |> lock("FOR UPDATE")
    |> preload([:message, :recipient_agent])
    |> Repo.one()
  end

  defp lease_delivery!(%Delivery{} = delivery, dispatch_lease_until) do
    delivery
    |> Ecto.Changeset.change(status: "leased", leased_until: dispatch_lease_until)
    |> Repo.update!()
  end

  defp deliver_prepared(
         %Delivery{message: %Message{} = message, recipient_agent: %Agent{} = recipient} =
           delivery
       ) do
    now = DateTime.utc_now(:microsecond)

    cond do
      delivery.status in ["delivered", "failed"] ->
        {:ok, message}

      acked?(message) ->
        stop_delivery_after_ack!(delivery, message)

      DateTime.compare(message.expires_at, now) != :gt ->
        expire_delivery!(delivery, message, now)

      true ->
        attempt_delivery(delivery, message, recipient, now)
    end
  end

  defp acked?(%Message{current_ack_status: status}), do: not is_nil(status)

  defp attempt_delivery(%Delivery{} = delivery, %Message{} = message, %Agent{} = recipient, now) do
    attempt_number = delivery.attempt_count + 1
    max_attempts = delivery.max_attempts || max_attempts(recipient)
    body = request_body(delivery, message)
    raw_body = Jason.encode!(body)
    timestamp = now |> DateTime.to_unix() |> Integer.to_string()

    request_result =
      case WebhookURL.connect_target(recipient.webhook_url, webhook_url_resolver()) do
        {:ok, target} ->
          target
          |> post_webhook(
            raw_body,
            request_headers(delivery, message, timestamp, raw_body, recipient)
          )
          |> classify_result(now, message, attempt_number, max_attempts)

        {:error, :unsafe_url} ->
          classify_result(
            {:error, :unsafe_webhook_url},
            now,
            message,
            attempt_number,
            max_attempts
          )
      end

    insert_attempt!(delivery, message, recipient, request_result)
    update_delivery!(delivery, request_result)
    update_message(message, request_result)
  end

  defp max_attempts(%Agent{} = recipient) do
    recipient
    |> account_plan()
    |> plan_attempts()
  end

  defp account_plan(%Agent{} = recipient) do
    Account
    |> where([account], account.id == ^recipient.account_id)
    |> select([account], account.plan)
    |> Repo.one()
  end

  defp plan_attempts("basic"), do: @basic_attempts
  defp plan_attempts(_plan), do: @free_attempts

  defp post_webhook(%ConnectTarget{} = target, raw_body, headers) do
    req_options()
    |> Keyword.merge(
      method: :post,
      url: target.url,
      body: raw_body,
      headers: [{"host", target.host_header} | headers],
      redirect: false,
      retry: false,
      receive_timeout: @timeout_ms
    )
    |> Keyword.update(:connect_options, connect_options(target), &connect_options(&1, target))
    |> Req.request()
  end

  defp connect_options(%ConnectTarget{} = target), do: connect_options([], target)

  defp connect_options(options, %ConnectTarget{} = target) do
    options
    |> Keyword.put(:hostname, target.hostname)
    |> Keyword.put_new(:timeout, @timeout_ms)
  end

  defp webhook_url_resolver do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:webhook_url_resolver, &WebhookURL.resolve_host/1)
  end

  defp req_options do
    :atp
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  defp request_headers(
         %Delivery{} = delivery,
         %Message{} = message,
         timestamp,
         raw_body,
         recipient
       ) do
    signature = WebhookSignature.sign(timestamp, raw_body, recipient.webhook_secret)

    [
      {"content-type", @content_type},
      {"atp-delivery-id", delivery.id},
      {"atp-message-id", message.id},
      {"atp-timestamp", timestamp},
      {"atp-signature", signature}
    ]
  end

  defp classify_result({:ok, %{status: status}}, now, _message, attempt_number, _max_attempts)
       when status >= 200 and status <= 299 do
    %{
      attempt_number: attempt_number,
      response_status: status,
      error: nil,
      result: "delivered",
      delivery_status: "delivered",
      message_status: "delivered",
      next_attempt_at: nil,
      delivered_at: now
    }
  end

  defp classify_result({:ok, %{status: 429}}, now, message, attempt_number, max_attempts),
    do: retry_or_fail(now, message, attempt_number, max_attempts, 429, nil)

  defp classify_result({:ok, %{status: status}}, now, message, attempt_number, max_attempts)
       when status >= 500 and status <= 599,
       do: retry_or_fail(now, message, attempt_number, max_attempts, status, nil)

  defp classify_result({:ok, %{status: status}}, _now, _message, attempt_number, _max_attempts),
    do: failed_result(attempt_number, status, nil)

  defp classify_result(
         {:error, :unsafe_webhook_url},
         _now,
         _message,
         attempt_number,
         _max_attempts
       ) do
    failed_result(attempt_number, nil, "unsafe_webhook_url")
  end

  defp classify_result({:error, reason}, now, message, attempt_number, max_attempts) do
    retry_or_fail(now, message, attempt_number, max_attempts, nil, Exception.message(reason))
  end

  defp retry_or_fail(now, message, attempt_number, max_attempts, response_status, error) do
    next_attempt_number = attempt_number + 1
    next_attempt_at = DateTime.add(now, retry_delay(next_attempt_number), :second)

    if retry_allowed?(attempt_number, max_attempts, next_attempt_at, message) do
      %{
        attempt_number: attempt_number,
        response_status: response_status,
        error: error,
        result: "retry_scheduled",
        delivery_status: "retry_scheduled",
        message_status: message.carrier_status,
        next_attempt_at: next_attempt_at,
        delivered_at: nil
      }
    else
      failed_result(attempt_number, response_status, error)
    end
  end

  defp retry_allowed?(attempt_number, max_attempts, next_attempt_at, %Message{} = message) do
    attempt_number < max_attempts and DateTime.compare(next_attempt_at, message.expires_at) == :lt
  end

  defp failed_result(attempt_number, response_status, error) do
    %{
      attempt_number: attempt_number,
      response_status: response_status,
      error: error,
      result: "failed",
      delivery_status: "failed",
      message_status: "delivery_failed",
      next_attempt_at: nil,
      delivered_at: nil
    }
  end

  defp retry_delay(next_attempt_number) do
    Enum.at(@retry_delays_seconds, next_attempt_number - 1, @max_retry_delay_seconds)
  end

  defp insert_attempt!(%Delivery{} = delivery, %Message{} = message, %Agent{} = recipient, result) do
    %WebhookAttempt{id: ID.generate("wha")}
    |> WebhookAttempt.changeset(%{
      delivery_id: delivery.id,
      message_id: message.id,
      recipient_agent_id: recipient.id,
      attempt_number: result.attempt_number,
      request_url: recipient.webhook_url,
      response_status: result.response_status,
      error: result.error,
      result: result.result,
      next_attempt_at: result.next_attempt_at
    })
    |> Repo.insert!()
  end

  defp update_delivery!(%Delivery{} = delivery, result) do
    delivery
    |> Ecto.Changeset.change(
      attempt_count: result.attempt_number,
      status: result.delivery_status,
      leased_until: nil,
      next_attempt_at: result.next_attempt_at,
      delivered_at: result.delivered_at,
      last_error: result.error
    )
    |> Repo.update!()
  end

  defp update_message(%Message{} = message, %{message_status: message_status}) do
    now = DateTime.utc_now(:microsecond)

    Message
    |> where([persisted_message], persisted_message.id == ^message.id)
    |> where([persisted_message], persisted_message.carrier_status != "delivered")
    |> Repo.update_all(set: [carrier_status: message_status, updated_at: now])

    {:ok, Repo.get!(Message, message.id)}
  end

  defp expire_delivery!(%Delivery{} = delivery, %Message{} = message, now) do
    delivery
    |> Ecto.Changeset.change(
      status: "failed",
      leased_until: nil,
      next_attempt_at: nil,
      last_error: "message_expired"
    )
    |> Repo.update!()

    Message
    |> where([persisted_message], persisted_message.id == ^message.id)
    |> where([persisted_message], persisted_message.carrier_status != "delivered")
    |> Repo.update_all(set: [carrier_status: "expired", terminal_at: now, updated_at: now])

    {:ok, Repo.get!(Message, message.id)}
  end

  defp stop_delivery_after_ack!(%Delivery{} = delivery, %Message{} = message) do
    delivery
    |> Ecto.Changeset.change(
      status: "failed",
      leased_until: nil,
      next_attempt_at: nil,
      last_error: "message_acked"
    )
    |> Repo.update!()

    {:ok, message}
  end

  defp request_body(%Delivery{} = delivery, %Message{} = message) do
    %{
      "delivery" => %{
        "id" => delivery.id,
        "mode" => "webhook"
      },
      "message" => MessageEnvelope.to_map(message)
    }
  end
end
