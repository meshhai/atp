defmodule Atp.Transport.WebhookSignature do
  @moduledoc """
  ATP webhook signature helpers for recipients.

  Signatures are Stripe-style HMAC headers over `timestamp <> "." <> raw_body`.
  Recipients should verify the raw request body exactly as received and reject
  timestamps outside their tolerance window.
  """

  @type verify_error :: :invalid_signature | :timestamp_out_of_tolerance

  @spec sign(String.t(), iodata(), String.t()) :: String.t()
  def sign(timestamp, body, secret)
      when is_binary(timestamp) and is_binary(secret) do
    raw_body = IO.iodata_to_binary(body)

    signature =
      :hmac
      |> :crypto.mac(:sha256, secret, timestamp <> "." <> raw_body)
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  @spec verify(String.t(), String.t(), iodata(), String.t(), non_neg_integer()) ::
          :ok | {:error, verify_error()}
  @spec verify(String.t(), String.t(), iodata(), String.t(), non_neg_integer(), integer()) ::
          :ok | {:error, verify_error()}
  def verify(signature_header, timestamp, body, secret, tolerance_seconds, now_unix \\ now_unix())
      when is_binary(signature_header) and is_binary(timestamp) and is_binary(secret) and
             is_integer(tolerance_seconds) and tolerance_seconds >= 0 and is_integer(now_unix) do
    with {:ok, timestamp_unix} <- parse_timestamp(timestamp),
         :ok <- validate_tolerance(timestamp_unix, now_unix, tolerance_seconds) do
      expected = sign(timestamp, body, secret)

      if Plug.Crypto.secure_compare(expected, signature_header) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp parse_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {timestamp_unix, ""} -> {:ok, timestamp_unix}
      _other -> {:error, :timestamp_out_of_tolerance}
    end
  end

  defp validate_tolerance(timestamp_unix, now_unix, tolerance_seconds) do
    if abs(now_unix - timestamp_unix) <= tolerance_seconds do
      :ok
    else
      {:error, :timestamp_out_of_tolerance}
    end
  end

  defp now_unix do
    DateTime.utc_now(:second)
    |> DateTime.to_unix()
  end
end
