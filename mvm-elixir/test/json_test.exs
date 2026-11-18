defmodule MvmEx.JsonTest do
  use ExUnit.Case, async: true
  alias MvmEx.Json

  test "encode sorts map keys (canonical form)" do
    assert Json.encode(%{"b" => 1, "a" => [true, nil, "x"]}) == ~s({"a":[true,null,"x"],"b":1})
  end

  test "decode round-trips nested manifests" do
    json = ~s({"format":"UORR4V12","shards":[{"index":0,"sha256":"ab"}],"n":3})
    assert {:ok, %{"format" => "UORR4V12", "shards" => [%{"index" => 0, "sha256" => "ab"}], "n" => 3}} = Json.decode(json)
  end

  test "decode rejects trailing garbage and bad input" do
    assert {:error, _} = Json.decode(~s({"a":1} junk))
    assert {:error, _} = Json.decode("not json")
  end

  test "string escapes round-trip" do
    assert {:ok, "a\nb\"c\\d"} = Json.decode(Json.encode("a\nb\"c\\d"))
  end
end
