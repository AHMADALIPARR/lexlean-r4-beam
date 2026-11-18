defmodule MvmEx.Audit do
  @moduledoc """
  Hash-chained audit log, ported from mvm's audit sink.

  Every launch is recorded before the VM boots. Each entry carries the
  SHA-256 of the previous entry, so tampering with any earlier entry
  breaks every hash after it. `verify/1` recomputes the whole chain.
  Entries are appended as one canonical JSON object per line.
  """

  alias MvmEx.Json

  @genesis String.duplicate("0", 64)

  @type entry :: %{
          seq: pos_integer(),
          prev: String.t(),
          event: String.t(),
          data: map(),
          hash: String.t()
        }

  @spec genesis() :: String.t()
  def genesis, do: @genesis

  @spec entry_hash(pos_integer(), String.t(), String.t(), map()) :: String.t()
  def entry_hash(seq, prev, event, data) do
    %{seq: seq, prev: prev, event: event, data: data}
    |> Json.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec build([map()]) :: {:ok, [entry()]} | {:error, String.t()}
  def build(events) when is_list(events) do
    {entries, _} =
      Enum.reduce(events, {[], @genesis}, fn %{event: event, data: data}, {acc, prev} ->
        seq = length(acc) + 1
        hash = entry_hash(seq, prev, event, data)
        entry = %{seq: seq, prev: prev, event: event, data: data, hash: hash}
        {[entry | acc], hash}
      end)

    {:ok, Enum.reverse(entries)}
  end

  @spec verify([entry()]) :: :ok | {:error, String.t()}
  def verify(entries) when is_list(entries) do
    result =
      Enum.reduce_while(entries, {@genesis, 1}, fn entry, {prev, seq} ->
        expected = entry_hash(seq, prev, entry.event, entry.data)

        cond do
          entry.seq != seq -> {:halt, {:error, "entry #{seq} has seq #{entry.seq}"}}
          entry.prev != prev -> {:halt, {:error, "entry #{seq} prev hash mismatch"}}
          entry.hash != expected -> {:halt, {:error, "entry #{seq} hash mismatch"}}
          true -> {:cont, {entry.hash, seq + 1}}
        end
      end)

    case result do
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  @spec append_to_file(Path.t(), String.t(), map()) ::
          {:ok, entry()} | {:error, String.t()}
  def append_to_file(path, event, data) when is_binary(path) do
    with {:ok, entries} <- read_file(path) do
      prev = entries |> List.last() |> then(fn nil -> @genesis; e -> e.hash end)
      seq = length(entries) + 1
      hash = entry_hash(seq, prev, event, data)
      entry = %{seq: seq, prev: prev, event: event, data: data, hash: hash}
      line = Json.encode(entry) <> "\n"

      case File.write(path, line, [:append]) do
        :ok -> {:ok, entry}
        {:error, reason} -> {:error, "cannot append audit log: #{inspect(reason)}"}
      end
    end
  end

  @spec read_file(Path.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true)

        Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
          case Json.decode(line) do
            {:ok, %{"seq" => seq, "prev" => prev, "event" => event, "data" => data, "hash" => hash}} ->
              {:cont, {:ok, acc ++ [%{seq: seq, prev: prev, event: event, data: data, hash: hash}]}}

            {:ok, _} ->
              {:halt, {:error, "audit log line is not an entry: #{String.slice(line, 0, 80)}"}}

            {:error, reason} ->
              {:halt, {:error, "audit log line does not parse: #{reason}"}}
          end
        end)

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "cannot read audit log: #{inspect(reason)}"}
    end
  end
end
