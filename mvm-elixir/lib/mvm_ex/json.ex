defmodule MvmEx.Json do
  @moduledoc """
  Minimal JSON encode/decode, standard library only (no Hex deps).

  `encode/1` sorts map keys, so it doubles as the canonical form used for
  plan digests and audit-chain hashes. `decode/1` is a small recursive
  descent parser: objects, arrays, strings (with \\u escapes), integers,
  floats, booleans and null. It is written for the weight manifests and
  the agent protocol, not as a general-purpose parser.
  """

  @spec encode(term()) :: String.t()
  def encode(nil), do: "null"
  def encode(true), do: "true"
  def encode(false), do: "false"
  def encode(n) when is_integer(n), do: Integer.to_string(n)

  def encode(f) when is_float(f) do
    if f == trunc(f) and abs(f) < 1.0e15 do
      Integer.to_string(trunc(f)) <> ".0"
    else
      :erlang.float_to_binary(f, [:short])
    end
  end

  def encode(s) when is_binary(s), do: encode_string(s)
  def encode(a) when is_atom(a), do: encode_string(Atom.to_string(a))

  def encode(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode/1) <> "]"
  end

  def encode(map) when is_map(map) do
    inner =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(",", fn {k, v} -> encode_string(k) <> ":" <> encode(v) end)

    "{" <> inner <> "}"
  end

  @spec canonical(term()) :: String.t()
  def canonical(term), do: encode(term)

  defp encode_string(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
      |> String.replace("\b", "\\b")
      |> String.replace("\f", "\\f")

    "\"" <> escaped <> "\""
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(binary) when is_binary(binary) do
    case parse_value(String.trim(binary)) do
      {:ok, value, rest} ->
        case String.trim(rest) do
          "" -> {:ok, value}
          other -> {:error, "trailing input: #{inspect(String.slice(other, 0, 40))}"}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_value(<<"{", rest::binary>>), do: parse_object(String.trim_leading(rest), %{})
  defp parse_value(<<"[", rest::binary>>), do: parse_array(String.trim_leading(rest), [])
  defp parse_value(<<"\"", rest::binary>>), do: parse_string(rest, "")

  defp parse_value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp parse_value(<<"null", rest::binary>>), do: {:ok, nil, rest}

  defp parse_value(bin) do
    case Regex.run(~r/\A-?\d+(\.\d+)?([eE][+-]?\d+)?/, bin) do
      [num | _] ->
        rest = binary_part(bin, byte_size(num), byte_size(bin) - byte_size(num))

        value =
          if String.contains?(num, ".") or String.contains?(num, "e") or
               String.contains?(num, "E") do
            String.to_float(num)
          else
            String.to_integer(num)
          end

        {:ok, value, rest}

      nil ->
        {:error, "cannot parse value at: #{inspect(String.slice(bin, 0, 40))}"}
    end
  end

  defp parse_object(<<"}", rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_object(bin, acc) do
    with <<"\"", rest::binary>> <- bin,
         {:ok, key, rest1} <- parse_string(rest, ""),
         rest2 <- String.trim_leading(rest1),
         <<":", rest3::binary>> <- rest2,
         {:ok, value, rest4} <- parse_value(String.trim_leading(rest3)),
         rest5 <- String.trim_leading(rest4) do
      acc = Map.put(acc, key, value)

      case rest5 do
        <<",", rest6::binary>> -> parse_object(String.trim_leading(rest6), acc)
        <<"}", rest6::binary>> -> {:ok, acc, rest6}
        _ -> {:error, "expected , or } in object"}
      end
    else
      _ -> {:error, "malformed object"}
    end
  end

  defp parse_array(<<"]", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_array(bin, acc) do
    with {:ok, value, rest1} <- parse_value(bin),
         rest2 <- String.trim_leading(rest1) do
      acc = [value | acc]

      case rest2 do
        <<",", rest3::binary>> -> parse_array(String.trim_leading(rest3), acc)
        <<"]", rest3::binary>> -> {:ok, Enum.reverse(acc), rest3}
        _ -> {:error, "expected , or ] in array"}
      end
    else
      err -> err
    end
  end

  defp parse_string(<<"\"", rest::binary>>, acc), do: {:ok, acc, rest}
  defp parse_string(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    {cp, ""} = Integer.parse(hex, 16)
    parse_string(rest, acc <> <<cp::utf8>>)
  end

  defp parse_string(<<"\\n", rest::binary>>, acc), do: parse_string(rest, acc <> "\n")
  defp parse_string(<<"\\r", rest::binary>>, acc), do: parse_string(rest, acc <> "\r")
  defp parse_string(<<"\\t", rest::binary>>, acc), do: parse_string(rest, acc <> "\t")
  defp parse_string(<<"\\b", rest::binary>>, acc), do: parse_string(rest, acc <> "\b")
  defp parse_string(<<"\\f", rest::binary>>, acc), do: parse_string(rest, acc <> "\f")
  defp parse_string(<<"\\/", rest::binary>>, acc), do: parse_string(rest, acc <> "/")
  defp parse_string(<<"\\\\", rest::binary>>, acc), do: parse_string(rest, acc <> "\\")
  defp parse_string(<<"\\\"", rest::binary>>, acc), do: parse_string(rest, acc <> "\"")

  defp parse_string(<<c::utf8, rest::binary>>, acc), do: parse_string(rest, acc <> <<c::utf8>>)
  defp parse_string("", _acc), do: {:error, "unterminated string"}
end
