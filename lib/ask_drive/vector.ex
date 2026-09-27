defmodule AskDrive.Vector do
  @moduledoc """
  Helper functions for converting between Elixir float lists and representations
  used by `sqlite-vec` and database storage.
  """

  @doc """
  Encodes a list of floats to JSON array string suitable for `sqlite-vec` queries and inserts.
  """
  @spec to_json([float()]) :: String.t()
  def to_json(floats) when is_list(floats) do
    Jason.encode!(floats)
  end

  @doc """
  Decodes a JSON array string to a list of floats.
  """
  @spec from_json(String.t()) :: [float()]
  def from_json(json_str) when is_binary(json_str) do
    Jason.decode!(json_str)
  end

  @doc """
  Encodes a list of floats into a binary BLOB of little-endian 32-bit floats.
  """
  @spec encode([float()]) :: binary()
  def encode(floats) when is_list(floats) do
    for f <- floats, into: <<>> do
      <<f::float-32-little>>
    end
  end

  @doc """
  Decodes a binary BLOB of little-endian 32-bit floats into a list of floats.
  """
  @spec decode(binary()) :: [float()]
  def decode(blob) when is_binary(blob) do
    for <<f::float-32-little <- blob>> do
      f
    end
  end
end
