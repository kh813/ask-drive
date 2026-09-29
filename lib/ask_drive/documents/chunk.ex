defmodule AskDrive.Documents.Chunk do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chunks" do
    belongs_to :document, AskDrive.Documents.Document
    field :position, :integer
    field :heading, :string
    field :content, :string
    field :content_hash, :string
    field :token_estimate, :integer
    field :page, :integer
    field :embedding, :binary
    field :reference_count, :integer, default: 0
    field :qa_attempts, :integer, default: 0
    field :qa_error, :string
    field :qa_attempted_at, :utc_datetime

    has_many :qa_pairs, AskDrive.QA.QAPair, on_delete: :nilify_all
    has_many :extractions, AskDrive.Documents.Extraction, on_delete: :nilify_all

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [
      :document_id,
      :position,
      :heading,
      :content,
      :content_hash,
      :page,
      :token_estimate,
      :embedding,
      :reference_count
    ])
    |> validate_required([:document_id, :position, :content, :content_hash])
    |> foreign_key_constraint(:document_id)
  end
end
