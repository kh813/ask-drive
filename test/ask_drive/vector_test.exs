defmodule AskDrive.VectorTest do
  use ExUnit.Case, async: true
  alias AskDrive.Vector

  test "encodes and decodes float lists to IEEE 754 float32 little endian" do
    floats = [0.1, -0.25, 1.5, 0.0]
    blob = Vector.encode(floats)
    assert byte_size(blob) == 16

    decoded = Vector.decode(blob)
    assert length(decoded) == 4

    Enum.zip(floats, decoded)
    |> Enum.each(fn {expected, actual} ->
      assert_in_delta expected, actual, 0.0001
    end)
  end
end
