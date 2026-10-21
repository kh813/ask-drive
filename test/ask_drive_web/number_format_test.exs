defmodule AskDriveWeb.NumberFormatTest do
  use ExUnit.Case, async: true

  import AskDriveWeb.NumberFormat

  test "a comma every 3 digits" do
    assert num(0) == "0"
    assert num(999) == "999"
    assert num(1_000) == "1,000"
    assert num(1_234_567) == "1,234,567"
    assert num(-12_345) == "-12,345"
    assert num(nil) == "0"
    assert num(1234.6) == "1,235"
  end

  test "Japanese cards: 万 and 億" do
    assert compact(9_999, "ja") == "9,999"
    assert compact(10_000, "ja") == "1 万"
    assert compact(123_456, "ja") == "12.3 万"
    assert compact(12_345_678, "ja") == "1,234 万"
    assert compact(123_456_789, "ja") == "1.2 億"
  end

  test "English cards: K, M and B" do
    assert compact(9_999, "en") == "9,999"
    assert compact(12_345, "en") == "12.3K"
    assert compact(123_456, "en") == "123K"
    assert compact(123_456_789, "en") == "123M"
    assert compact(1_234_567_890, "en") == "1.2B"
  end
end
