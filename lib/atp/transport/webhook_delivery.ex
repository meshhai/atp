defmodule Atp.Transport.WebhookDelivery do
  @moduledoc "Signed ATP webhook delivery and retry classification."

  import Ecto.Query

  alias Atp.Identity.{Account, Agent, ID, WebhookURL}
  alias Atp.Identity.WebhookURL.ConnectTarget
  alias Atp.Repo

  alias Atp.Transport.{
    Delivery,
    DeliveryClaim,
    DurableLedger,
    Message,
    MessageEnvelope,
    WebhookSignature
  }

  alias Atp.Transport.WebhookDelivery.AttemptResult

  @content_type "application/json"
  @free_attempts 3
  @basic_attempts 8
  @retry_delays_seconds [0, 30, 120, 300, 900, 3_600, 21_600, 86_400]
  @max_retry_delay_seconds 86_400
  @dispatch_lease_seconds 60
  @internal_task_exit_error "internal_task_exit"
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
    case DurableLedger.claim_webhook_delivery(delivery_id,
           lease_seconds: @dispatch_lease_seconds
         ) do
      {:error, reason} -> {:error, reason}
      {:ok, %Message{} = message} -> {:ok, message}
      {:ok, %DeliveryClaim{} = claim} -> deliver_claim(claim)
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
    lease_seconds = Keyword.get(opts, :lease_seconds, @dispatch_lease_seconds)

    {:ok, deliver_due_claims(limit, lease_seconds)}
  end

  @doc false
  @spec deliver_claim(DeliveryClaim.t()) :: delivery_result()
  def deliver_claim(
        %DeliveryClaim{
          delivery: %Delivery{} = delivery,
          message: %Message{} = message,
          recipient_agent: %Agent{} = recipient
        } = claim
      ) do
    now = DateTime.utc_now(:microsecond)

    cond do
      delivery.status in ["delivered", "failed"] ->
        {:ok, message}

      acked?(message) ->
        DurableLedger.terminalize_claimed_webhook_delivery(claim, :message_acked, now: now)

      DateTime.compare(message.expires_at, now) != :gt ->
        DurableLedger.terminalize_claimed_webhook_delivery(claim, :message_expired, now: now)

      not active_webhook_endpoint?(recipient) ->
        DurableLedger.terminalize_claimed_webhook_delivery(
          claim,
          :webhook_endpoint_inactive,
          now: now
        )

      true ->
        attempt_delivery(claim, recipient, now)
    end
  end

  @doc false
  @spec record_task_exit(DeliveryClaim.t()) :: delivery_result()
  def record_task_exit(
        %DeliveryClaim{
          delivery: %Delivery{} = delivery,
          message: %Message{} = message,
          recipient_agent: %Agent{} = recipient,
          attempt_number: attempt_number
        } = claim
      ) do
    now = DateTime.utc_now(:microsecond)
    max_attempts = delivery.max_attempts || max_attempts(recipient)

    result =
      retry_or_fail(
        now,
        message,
        attempt_number,
        max_attempts,
        nil,
        @internal_task_exit_error
      )

    DurableLedger.finish_claimed_webhook_delivery(claim, result, now: now)
  end

  defp deliver_due_claims(limit, lease_seconds) when is_integer(limit) and limit > 0 do
    claim_due_claims(limit, [], lease_seconds)
  end

  defp deliver_due_claims(_limit, _lease_seconds), do: []

  defp claim_due_claims(0, results, _lease_seconds), do: Enum.reverse(results)

  defp claim_due_claims(remaining, results, lease_seconds) do
    case DurableLedger.claim_due_webhook_delivery(lease_seconds: lease_seconds) do
      {:ok, nil} ->
        Enum.reverse(results)

      {:ok, %DeliveryClaim{} = claim} ->
        claim_due_claims(remaining - 1, [deliver_claim(claim) | results], lease_seconds)

      {:error, reason} ->
        Enum.reverse([{:error, reason} | results])
    end
  end

  defp acked?(%Message{current_ack_status: status}), do: not is_nil(status)

  defp active_webhook_endpoint?(%Agent{
         webhook_active: true,
         webhook_url: url,
         webhook_secret: secret
       })
       when is_binary(url) and is_binary(secret) do
    String.trim(url) != "" and String.trim(secret) != ""
  end

  defp active_webhook_endpoint?(%Agent{}), do: false

  defp attempt_delivery(
         %DeliveryClaim{delivery: delivery, message: message, attempt_number: attempt_number} =
           claim,
         %Agent{} = recipient,
         now
       ) do
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

    DurableLedger.finish_claimed_webhook_delivery(claim, request_result)
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
    %AttemptResult{
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
      %AttemptResult{
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
    %AttemptResult{
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
