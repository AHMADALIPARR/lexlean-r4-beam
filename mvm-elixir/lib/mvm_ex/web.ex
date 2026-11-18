defmodule MvmEx.Web do
  @moduledoc """
  Minimal HTTP host for the in-browser web LLM page.

  Serves `web/index.html` plus a JSON API:
  - GET  /api/weights        weight-pack inventory from the manifests
  - POST /api/weights/verify {pack}   hash-verify one pack's shards
  - POST /api/vm/run         {command, pack?} — gate the command, run it
                             in a software-backend microVM session with
                             the pack mounted read-only, return output
  - GET  /api/vm             pool + standby summary

  Plain `:gen_tcp`, no dependencies. This is the host side; the page
  itself is static HTML/JS that fetches the API. The integer inference
  engine that runs a pack in the browser is upstream `crates/wasm`,
  which is not part of this `gpu/` clone — see STATUS.md.
  """

  use GenServer

  alias MvmEx.{Json, Plan, Pool, VM, Weights}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  @impl true
  def init(port) do
    {:ok, listen} = :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true])
    send(self(), :accept)
    {:ok, %{listen: listen, port: port}}
  end

  @impl true
  def handle_info(:accept, %{listen: listen} = state) do
    case :gen_tcp.accept(listen, 1000) do
      {:ok, socket} ->
        Task.start(fn -> handle_conn(socket) end)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp handle_conn(socket) do
    with {:ok, req} <- read_request(socket) do
      {status, content_type, body} = route(req)
      send_response(socket, status, content_type, body)
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, head, rest} <- read_until(socket, "\r\n\r\n", 65_536),
         [request_line | header_lines] <- String.split(head, "\r\n", trim: true),
         [method, path, _version] <- String.split(request_line, " "),
         headers <- parse_headers(header_lines),
         {:ok, body} <- read_body(socket, headers, rest) do
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp read_until(socket, marker, max) do
    read_until(socket, marker, max, "")
  end

  defp read_until(_socket, _marker, max, acc) when byte_size(acc) > max, do: {:error, :too_large}

  defp read_until(socket, marker, max, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data

        case :binary.split(acc, marker) do
          [head, rest] -> {:ok, head <> marker, rest}
          [_] -> read_until(socket, marker, max, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.downcase(String.trim(k)), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp read_body(socket, headers, buffered) do
    case Map.get(headers, "content-length") do
      nil ->
        {:ok, ""}

      len ->
        case Integer.parse(len) do
          {n, ""} when n >= 0 and n <= 1_048_576 ->
            have = byte_size(buffered)

            cond do
              have >= n ->
                {:ok, binary_part(buffered, 0, n)}

              true ->
                case :gen_tcp.recv(socket, n - have, 5_000) do
                  {:ok, more} -> {:ok, buffered <> more}
                  {:error, reason} -> {:error, reason}
                end
            end

          _ ->
            {:error, :bad_length}
        end
    end
  end

  defp route(%{method: "GET", path: "/"}) do
    {200, "text/html", web_file("index.html")}
  end

  defp route(%{method: "GET", path: "/api/weights"}) do
    body =
      case Weights.gpu_root() do
        {:ok, root} -> Json.encode(%{"packs" => Weights.inventory(root)})
        {:error, reason} -> Json.encode(%{"error" => reason})
      end

    {200, "application/json", body}
  end

  defp route(%{method: "POST", path: "/api/weights/verify", body: body}) do
    with {:ok, %{"pack" => pack_id}} <- Json.decode(body),
         {:ok, root} <- Weights.gpu_root(),
         {:ok, result} <- Weights.verify_pack(root, pack_id) do
      {200, "application/json", Json.encode(result)}
    else
      {:error, reason} -> {400, "application/json", Json.encode(%{"error" => to_string(reason)})}
      _ -> {400, "application/json", Json.encode(%{"error" => "bad request"})}
    end
  end

  defp route(%{method: "GET", path: "/api/vm"}) do
    {200, "application/json", Json.encode(Pool.list())}
  end

  defp route(%{method: "POST", path: "/api/vm/run", body: body}) do
    with {:ok, %{"command" => command}} <- Json.decode(body),
         {:ok, plan} <-
           Plan.synthesize(%{
             "id" => "web-#{:erlang.unique_integer([:positive])}",
             "image" => "alpine",
             "command" => command
           }),
         {:ok, instance} <-
           MvmEx.Instance.new(%{"id" => plan.id, "image" => plan.image, "command" => command}),
         {:ok, pid} <- VM.start_link(instance, mounts: mounts_for(body)),
         {:ok, result} <- VM.exec(pid, command, plan.timeout_s * 1000) do
      VM.stop(pid)
      {200, "application/json", Json.encode(%{"ok" => true, "output" => result.output, "exit_status" => result.exit_status})}
    else
      {:error, {:blocked, pattern, category}} ->
        {403, "application/json", Json.encode(%{"ok" => false, "error" => "blocked by command gate", "pattern" => pattern, "category" => category})}

      {:error, {:requires_approval, pattern, category}} ->
        {403, "application/json", Json.encode(%{"ok" => false, "error" => "requires approval", "pattern" => pattern, "category" => category})}

      {:error, reason} ->
        {400, "application/json", Json.encode(%{"ok" => false, "error" => to_string(reason)})}

      _ ->
        {400, "application/json", Json.encode(%{"ok" => false, "error" => "bad request"})}
    end
  end

  defp route(_req), do: {404, "application/json", Json.encode(%{"error" => "not found"})}

  defp mounts_for(body) do
    with {:ok, %{"pack" => pack_id}} <- Json.decode(body),
         {:ok, root} <- Weights.gpu_root() do
      case pack_id do
        "v8" -> [{Path.join(root, "weights/uor_r4_glm_v8.uorlut.part000"), "pack.part000"}]
        "v9" -> [{Path.join(root, "weights/v9"), "pack"}]
        "v10" -> [{Path.join(root, "weights/v10"), "pack"}]
        _ -> []
      end
    else
      _ -> []
    end
  end

  defp web_file(name) do
    path = Path.join([File.cwd!(), "web", name])

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> "<h1>mvm-ex web page missing: #{name}</h1>"
    end
  end

  defp send_response(socket, status, content_type, body) do
    reason = %{200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found"}[status] || "OK"

    response =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "Content-Type: #{content_type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    :gen_tcp.send(socket, response)
  end
end
