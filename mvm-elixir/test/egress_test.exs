defmodule MvmEx.EgressTest do
  use ExUnit.Case, async: true
  alias MvmEx.Egress

  test "default-deny: unlisted hosts are denied" do
    req = %{host: "evil.example", path: "/x", headers: %{}}
    assert {:error, :denied} = Egress.resolve(req, ["huggingface.co"], %{})
  end

  test "allowlisted host resolves; placeholders are substituted host-side" do
    req = %{host: "huggingface.co", path: "/api/models", headers: %{"Authorization" => "Bearer ${SECRET:HF_TOKEN}"}}
    secrets = %{"HF_TOKEN" => "real-token-value"}
    assert {:ok, resolved} = Egress.resolve(req, ["huggingface.co"], secrets)
    assert resolved.headers["Authorization"] == "Bearer real-token-value"
  end

  test "unknown secret placeholder is an error, never passed through raw" do
    req = %{host: "huggingface.co", path: "/", headers: %{"Authorization" => "Bearer ${SECRET:NOPE}"}}
    assert {:error, {:unknown_secret, "NOPE"}} = Egress.resolve(req, ["huggingface.co"], %{})
  end

  test "substitute_value leaves plain values alone" do
    assert {:ok, "plain"} = Egress.substitute_value("plain", %{})
  end
end
