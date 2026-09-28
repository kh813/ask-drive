defmodule AskDrive.Vector do
  @moduledoc """
  Helper functions for converting between Elixir float lists and representations
  used by `sqlite-vec` and database storage, plus rebuilding the vector virtual tables when
  the embedding dimension changes.
  """

  alias AskDrive.Repo

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

  @doc """
  Rebuilds the `sqlite-vec` virtual tables for a new embedding dimension and discards every
  stored vector (spec 6.8 F-809).

  `vec0` fixes the vector width at CREATE time, so changing `settings.embedding_dim` means
  dropping and recreating the tables. Existing vectors are unusable afterwards regardless —
  they were produced by a different model — so the chunk and question embeddings are cleared
  and the QA pairs are marked `stale` for the next nightly batch to regenerate.
  """
  @spec rebuild_index(pos_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def rebuild_index(dim) when is_integer(dim) and dim > 0 do
    Repo.transaction(fn ->
      Repo.query!("DROP TABLE IF EXISTS vec_chunks;")
      Repo.query!("DROP TABLE IF EXISTS vec_qa_pairs;")

      Repo.query!("""
      CREATE VIRTUAL TABLE vec_chunks USING vec0(
        chunk_id INTEGER PRIMARY KEY,
        embedding float[#{dim}] distance_metric=cosine
      );
      """)

      Repo.query!("""
      CREATE VIRTUAL TABLE vec_qa_pairs USING vec0(
        qa_pair_id INTEGER PRIMARY KEY,
        question_embedding float[#{dim}] distance_metric=cosine
      );
      """)

      Repo.query!("UPDATE chunks SET embedding = NULL;")
      Repo.query!("UPDATE qa_pairs SET question_embedding = NULL, status = 'stale';")
      # Cached answers point at QA pairs that are now stale, so they must not be served.
      Repo.query!("DELETE FROM answer_cache;")

      dim
    end)
  end
end
