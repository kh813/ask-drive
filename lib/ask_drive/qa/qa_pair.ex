defmodule AskDrive.QA.QAPair do
  use Ecto.Schema
  import Ecto.Changeset

  schema "qa_pairs" do
    belongs_to :document, AskDrive.Documents.Document
    belongs_to :chunk, AskDrive.Documents.Chunk
    field :question, :string
    field :answer, :string
    field :question_embedding, :binary
    field :source_hash, :string
    field :status, :string, default: "active"
    field :hallucination_flag, :boolean, default: false
    field :generated_by, :string
    field :generated_at, :utc_datetime
    field :hit_count, :integer, default: 0

    has_many :answer_caches, AskDrive.QA.AnswerCache, on_delete: :delete_all

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(qa_pair, attrs) do
    qa_pair
    |> cast(attrs, [
      :document_id,
      :chunk_id,
      :question,
      :answer,
      :question_embedding,
      :source_hash,
      :status,
      :hallucination_flag,
      :generated_by,
      :generated_at,
      :hit_count
    ])
    |> validate_required([:document_id, :question, :answer, :source_hash, :generated_by])
    |> validate_inclusion(:status, ["active", "stale", "failed"])
    |> foreign_key_constraint(:document_id)
    |> foreign_key_constraint(:chunk_id)
  end
end
