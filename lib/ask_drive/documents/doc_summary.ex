defmodule AskDrive.Documents.DocSummary do
  use Ecto.Schema
  import Ecto.Changeset

  schema "doc_summaries" do
    belongs_to :document, AskDrive.Documents.Document
    field :scope, :string, default: "document"
    field :heading, :string
    field :summary, :string
    field :source_hashes, {:array, :string}
    field :status, :string, default: "active"
    field :generated_by, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(doc_summary, attrs) do
    doc_summary
    |> cast(attrs, [
      :document_id,
      :scope,
      :heading,
      :summary,
      :source_hashes,
      :status,
      :generated_by
    ])
    |> validate_required([:document_id, :scope, :summary, :generated_by])
    |> validate_inclusion(:scope, ["document", "section"])
    |> validate_inclusion(:status, ["active", "stale"])
    |> foreign_key_constraint(:document_id)
  end
end
