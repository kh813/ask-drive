defmodule AskDrive.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  schema "documents" do
    field :drive_file_id, :string
    field :name, :string
    field :mime_type, :string
    field :path, :string
    field :web_view_link, :string
    field :modified_time, :utc_datetime
    field :content_hash, :string
    field :size_bytes, :integer
    field :status, :string, default: "pending"
    field :error, :string
    field :synced_at, :utc_datetime

    has_many :chunks, AskDrive.Documents.Chunk, on_delete: :delete_all
    has_many :qa_pairs, AskDrive.QA.QAPair, on_delete: :delete_all
    has_many :doc_summaries, AskDrive.Documents.DocSummary, on_delete: :delete_all
    has_many :extractions, AskDrive.Documents.Extraction, on_delete: :delete_all

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :drive_file_id,
      :name,
      :mime_type,
      :path,
      :web_view_link,
      :modified_time,
      :content_hash,
      :size_bytes,
      :status,
      :error,
      :synced_at
    ])
    |> validate_required([:drive_file_id, :name, :mime_type])
    |> unique_constraint(:drive_file_id)
    |> validate_inclusion(:status, ["pending", "fetching", "indexed", "skipped", "failed"])
  end
end
