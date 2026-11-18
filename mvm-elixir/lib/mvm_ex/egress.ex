defmodule MvmEx.Egress do
  @moduledoc """
  Default-deny egress, ported from mvm's host-side vsock proxy model.

  A workload VM has no network device. Everything the guest sends goes
  over vsock to a per-VM process on the host, and that process opens any
  outbound connection itself. The host is the one place where
  default-deny egress is enforced and where secret placeholders are
  swapped for real credentials, so the guest never holds them.

  `resolve/3` is the pure enforcement point: given the guest's request
  (which may only name placeholders like `${SECRET:HF_TOKEN}`), the
  allowlist and the host-side secret store, it either returns the
  host-side request to perform, or `:denied`. The guest never sees the
  resolved values.
  """

  @type request :: %{host: String.t(), path: String.t(), headers: %{String.t() => String.t()}}

  @spec resolve(request(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, request()} | {:error, :denied | {:unknown_secret, String.t()}}
  def resolve(%{host: host} = req, allowlist, secrets)
      when is_binary(host) and is_list(allowlist) and is_map(secrets) do
    if host in allowlist do
      with {:ok, headers} <- substitute_headers(Map.get(req, :headers, %{}), secrets) do
        {:ok, %{req | headers: headers}}
      end
    else
      {:error, :denied}
    end
  end

  @spec substitute_headers(%{String.t() => String.t()}, %{String.t() => String.t()}) ::
          {:ok, %{String.t() => String.t()}} | {:error, {:unknown_secret, String.t()}}
  def substitute_headers(headers, secrets) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case substitute_value(v, secrets) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, k, resolved)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec substitute_value(String.t(), %{String.t() => String.t()}) ::
          {:ok, String.t()} | {:error, {:unknown_secret, String.t()}}
  def substitute_value(value, secrets) when is_binary(value) do
    Regex.replace(~r/\$\{SECRET:([A-Za-z0-9_]+)\}/, value, fn _, name ->
      case Map.fetch(secrets, name) do
        {:ok, secret} -> secret
        :error -> throw({:unknown_secret, name})
      end
    end)
    |> then(&{:ok, &1})
  catch
    {:unknown_secret, name} -> {:error, {:unknown_secret, name}}
  end

  @spec fetch(request(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, %{status: integer(), body: binary()}}
          | {:error, :denied | {:unknown_secret, String.t()} | {:http, term()}}
  def fetch(%{host: host, path: path} = req, allowlist, secrets) do
    with {:ok, resolved} <- resolve(req, allowlist, secrets) do
      url = String.to_charlist("https://#{host}#{path}")
      headers = Enum.map(resolved.headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

      # apply/3: :httpc lives in the :inets application, which is started
      # with this app but is not on the compiler's path at build time.
      case apply(:httpc, :request, [:get, {url, headers}, [{:ssl, [{:verify, :verify_none}]}], [body_format: :binary]]) do
        {:ok, {{_vsn, status, _reason}, _resp_headers, body}} ->
          {:ok, %{status: status, body: body}}

        {:error, reason} ->
          {:error, {:http, reason}}
      end
    end
  end
end
