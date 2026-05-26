defmodule Atp.WebhookURLTest do
  use ExUnit.Case, async: true

  alias Atp.Identity.WebhookURL

  test "resolved public URL helper accepts only URLs whose resolved addresses are public" do
    public_resolver = fn "recipient.example.test" -> {:ok, [{93, 184, 216, 34}]} end
    private_resolver = fn "recipient.example.test" -> {:ok, [{10, 0, 0, 1}]} end
    missing_resolver = fn "recipient.example.test" -> {:error, :nxdomain} end

    refute WebhookURL.public_resolved_http_url?("http://localhost/atp/webhook")

    assert WebhookURL.public_resolved_http_url?(
             "https://recipient.example.test/atp/webhook",
             public_resolver
           )

    refute WebhookURL.public_resolved_http_url?(
             "https://recipient.example.test/atp/webhook",
             private_resolver
           )

    refute WebhookURL.public_resolved_http_url?(
             "https://recipient.example.test/atp/webhook",
             missing_resolver
           )
  end

  test "connect target pins DNS delivery to the resolved public address" do
    resolver = fn "recipient.example.test" -> {:ok, [{93, 184, 216, 34}]} end

    assert {:error, :unsafe_url} = WebhookURL.connect_target("http://localhost/atp/webhook")

    assert {:ok, target} =
             WebhookURL.connect_target(
               "https://recipient.example.test:8443/atp/webhook?mode=safe",
               resolver
             )

    assert target.url == "https://93.184.216.34:8443/atp/webhook?mode=safe"
    assert target.hostname == "recipient.example.test"
    assert target.host_header == "recipient.example.test:8443"
  end

  test "connect target accepts public IP literals and preserves host header formatting" do
    reject_resolver = fn _host -> flunk("literal IPs must not resolve through DNS") end

    assert {:ok, ipv4_target} =
             WebhookURL.connect_target("https://8.8.8.8/atp/webhook", reject_resolver)

    assert ipv4_target.url == "https://8.8.8.8/atp/webhook"
    assert ipv4_target.host_header == "8.8.8.8"

    assert {:ok, ipv6_target} =
             WebhookURL.connect_target(
               "https://[2001:4860:4860::8888]:8443/atp/webhook",
               reject_resolver
             )

    assert ipv6_target.host_header == "[2001:4860:4860::8888]:8443"
  end

  test "embedded IPv4 IPv6 literals use the embedded IPv4 safety policy" do
    resolver = fn _host -> flunk("literal IPs must not resolve through DNS") end

    assert {:ok, _target} = WebhookURL.connect_target("http://[::ffff:808:808]/hook", resolver)
    assert {:ok, _target} = WebhookURL.connect_target("http://[::808:808]/hook", resolver)
    assert {:ok, _target} = WebhookURL.connect_target("http://[64:ff9b::808:808]/hook", resolver)
    refute WebhookURL.public_http_url?("http://[::ffff:192.0.0.1]/hook")
  end

  test "host resolver normalizes address families and missing hosts" do
    assert {:ok, [_address | _]} = WebhookURL.resolve_host("localhost")

    assert {:error, :not_found} =
             WebhookURL.resolve_host("missing-#{System.unique_integer([:positive])}.invalid")
  end
end
