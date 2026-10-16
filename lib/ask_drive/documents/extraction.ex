defmodule AskDrive.Documents.Extraction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "extractions" do
    belongs_to :document, AskDrive.Documents.Document
    belongs_to :chunk, AskDrive.Documents.Chunk
    field :key, :string
    field :value, :string
    field :value_type, :string, default: "text"
    field :status, :string, default: "active"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(extraction, attrs) do
    extraction
    |> cast(attrs, [:document_id, :chunk_id, :key, :value, :value_type, :status])
    |> validate_required([:document_id, :key, :value])
    |> validate_inclusion(:value_type, ["date", "money", "text", "number"])
    |> validate_inclusion(:status, ["active", "stale"])
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:chunk_id)
  end
end
