defmodule Atp.Identity.WebhookURL do
  @moduledoc """
  Validation policy for agent webhook endpoint URLs.

  This blocks localhost and literal private, link-local, multicast, and reserved
  IP addresses. DNS names are accepted during endpoint setup, then resolved and
  checked again immediately before delivery. Delivery uses the returned
  connection target so the socket connects to the same IP address that passed
  validation.
  """

  alias Atp.Identity.WebhookURL.ConnectTarget

  @spec public_http_url?(String.t()) :: boolean()
  def public_http_url?(url) when is_binary(url) do
    case public_http_url_host(url) do
      {:ok, host} -> public_host_literal_or_name?(host)
      :error -> false
    end
  end

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @spec public_resolved_http_url?(String.t(), resolver()) :: boolean()
  def public_resolved_http_url?(url, resolver \\ &resolve_host/1)
      when is_binary(url) and is_function(resolver, 1) do
    match?({:ok, %ConnectTarget{}}, connect_target(url, resolver))
  end

  @spec connect_target(String.t(), resolver()) :: {:ok, ConnectTarget.t()} | {:error, :unsafe_url}
  def connect_target(url, resolver \\ &resolve_host/1)
      when is_binary(url) and is_function(resolver, 1) do
    with {:ok, uri, host} <- public_http_uri(url),
         true <- public_host_literal_or_name?(host),
         {:ok, address} <- public_connect_address(host, resolver) do
      {:ok,
       %ConnectTarget{
         url: connect_url(uri, address),
         hostname: host,
         host_header: host_header(uri, host)
       }}
    else
      _ -> {:error, :unsafe_url}
    end
  end

  @spec resolve_host(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, :not_found}
  def resolve_host(host) when is_binary(host) do
    host_chars = String.to_charlist(host)

    addresses =
      (resolve_inet_addresses(host_chars, :inet) ++ resolve_inet_addresses(host_chars, :inet6))
      |> Enum.uniq()

    case addresses do
      [] -> {:error, :not_found}
      addresses -> {:ok, addresses}
    end
  end

  defp public_http_url_host(url) do
    with {:ok, _uri, host} <- public_http_uri(url) do
      {:ok, host}
    end
  end

  defp public_http_uri(url) do
    uri =
      url
      |> String.trim()
      |> URI.parse()

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      case uri.host |> String.trim() |> String.downcase() do
        "" -> :error
        host -> {:ok, uri, host}
      end
    else
      :error
    end
  end

  defp public_host_literal_or_name?(host) when is_binary(host) do
    not localhost?(host) and public_host_literal?(host)
  end

  defp localhost?("localhost"), do: true
  defp localhost?(host), do: String.ends_with?(host, ".localhost")

  defp public_host_literal?(host) do
    case parse_ip_address(host) do
      {:ok, address} -> public_ip_address?(address)
      :error -> true
    end
  end

  defp public_connect_address(host, resolver) do
    case parse_ip_address(host) do
      {:ok, address} ->
        if public_ip_address?(address), do: {:ok, address}, else: :error

      :error ->
        case resolver.(host) do
          {:ok, [_address | _] = addresses} ->
            if Enum.all?(addresses, &public_ip_address?/1), do: {:ok, hd(addresses)}, else: :error

          _other ->
            :error
        end
    end
  end

  defp resolve_inet_addresses(host, family) do
    case :inet.getaddrs(host, family) do
      {:ok, addresses} -> addresses
      {:error, _reason} -> []
    end
  end

  defp parse_ip_address(host) do
    host
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> {:ok, address}
      {:error, :einval} -> :error
    end
  end

  defp public_ip_address?({first, second, third, fourth}) do
    not private_or_special_ipv4_address?(first, second, third, fourth)
  end

  defp public_ip_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip_address?({0, 0, 0, 0, 0, 0xFFFF, seventh, eighth}) do
    public_embedded_ipv4_address?(seventh, eighth)
  end

  defp public_ip_address?({0, 0, 0, 0, 0, 0, seventh, eighth}) do
    public_embedded_ipv4_address?(seventh, eighth)
  end

  defp public_ip_address?({0x0064, 0xFF9B, 0, 0, 0, 0, seventh, eighth}) do
    public_embedded_ipv4_address?(seventh, eighth)
  end

  defp public_ip_address?({first, _second, _third, _fourth, _fifth, _sixth, _seventh, _eighth}) do
    not (first in 0xFC00..0xFDFF or first in 0xFE80..0xFEBF or first in 0xFF00..0xFFFF)
  end

  defp public_embedded_ipv4_address?(seventh, eighth) do
    first = div(seventh, 256)
    second = rem(seventh, 256)
    third = div(eighth, 256)
    fourth = rem(eighth, 256)

    public_ip_address?({first, second, third, fourth})
  end

  defp connect_url(%URI{} = uri, address) do
    uri
    |> Map.put(:host, address_to_string(address))
    |> URI.to_string()
  end

  defp address_to_string(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  end

  defp host_header(%URI{} = uri, host) do
    host = bracket_ipv6_host(host)
    port = uri.port || URI.default_port(uri.scheme)

    if is_nil(port) or port == URI.default_port(uri.scheme) do
      host
    else
      "#{host}:#{port}"
    end
  end

  defp bracket_ipv6_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  defp private_or_special_ipv4_address?(first, second, third, _fourth) do
    first in [0, 10, 127] or
      carrier_grade_nat_ipv4_address?(first, second) or
      link_local_ipv4_address?(first, second) or
      private_172_ipv4_address?(first, second) or
      private_192_ipv4_address?(first, second, third) or
      benchmarking_ipv4_address?(first, second) or
      documentation_ipv4_address?(first, second, third) or
      multicast_or_reserved_ipv4_address?(first)
  end

  defp carrier_grade_nat_ipv4_address?(100, second), do: second in 64..127
  defp carrier_grade_nat_ipv4_address?(_first, _second), do: false

  defp link_local_ipv4_address?(169, 254), do: true
  defp link_local_ipv4_address?(_first, _second), do: false

  defp private_172_ipv4_address?(172, second), do: second in 16..31
  defp private_172_ipv4_address?(_first, _second), do: false

  defp private_192_ipv4_address?(192, 0, 0), do: true
  defp private_192_ipv4_address?(192, 168, _third), do: true
  defp private_192_ipv4_address?(_first, _second, _third), do: false

  defp benchmarking_ipv4_address?(198, second), do: second in 18..19
  defp benchmarking_ipv4_address?(_first, _second), do: false

  defp documentation_ipv4_address?(192, 0, 2), do: true
  defp documentation_ipv4_address?(198, 51, 100), do: true
  defp documentation_ipv4_address?(203, 0, 113), do: true
  defp documentation_ipv4_address?(_first, _second, _third), do: false

  defp multicast_or_reserved_ipv4_address?(first), do: first >= 224
end
