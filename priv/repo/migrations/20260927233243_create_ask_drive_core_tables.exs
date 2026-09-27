defmodule AskDrive.Repo.Migrations.CreateAskDriveCoreTables do
  use Ecto.Migration

  def up do
    # 1. settings (singleton configuration)
    create table(:settings) do
      add :drive_folder_id, :string
      add :drive_folder_name, :string
      add :batch_start_hour, :integer, default: 21, null: false
      add :batch_end_hour, :integer, default: 7, null: false
      add :batch_model, :string, default: "qwen3:4b", null: false
      add :embed_model, :string, default: "bge-m3", null: false
      add :batch_num_ctx, :integer, default: 4096, null: false
      add :similarity_threshold, :float, default: 0.65, null: false
      add :serve_stale_qa, :boolean, default: false, null: false
      add :daytime_llm_enabled, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    # 2. google_accounts (singleton OAuth credentials)
    create table(:google_accounts) do
      add :email, :string
      add :access_token, :binary
      add :refresh_token, :binary
      add :token_expires_at, :utc_datetime
      add :scope, :string
      add :status, :string, default: "connected", null: false

      timestamps(type: :utc_datetime)
    end

    # 3. documents
    create table(:documents) do
      add :drive_file_id, :string, null: false
      add :name, :string, null: false
      add :mime_type, :string, null: false
      add :path, :string
      add :web_view_link, :string
      add :modified_time, :utc_datetime
      add :content_hash, :string
      add :size_bytes, :bigint
      add :status, :string, default: "pending", null: false
      add :error, :text
      add :synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:documents, [:drive_file_id])
    create index(:documents, [:status])
    create index(:documents, [:content_hash])

    # 4. chunks
    create table(:chunks) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :heading, :string
      add :content, :text, null: false
      add :content_hash, :string, null: false
      add :token_estimate, :integer
      add :embedding, :binary
      add :reference_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:chunks, [:document_id])
    create index(:chunks, [:content_hash])

    # 5. qa_pairs
    create table(:qa_pairs) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :chunk_id, references(:chunks, on_delete: :nilify_all)
      add :question, :text, null: false
      add :answer, :text, null: false
      add :question_embedding, :binary
      add :source_hash, :string, null: false
      add :status, :string, default: "active", null: false
      add :hallucination_flag, :boolean, default: false, null: false
      add :generated_by, :string, null: false
      add :generated_at, :utc_datetime
      add :hit_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:qa_pairs, [:document_id, :status])
    create index(:qa_pairs, [:chunk_id, :status])
    create index(:qa_pairs, [:status, :generated_by])

    # 6. answer_cache (Tier 0 cache)
    create table(:answer_cache) do
      add :normalized_question, :string, null: false
      add :qa_pair_id, references(:qa_pairs, on_delete: :delete_all), null: false
      add :hit_count, :integer, default: 1, null: false
      add :last_hit_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:answer_cache, [:normalized_question])
    create index(:answer_cache, [:qa_pair_id])

    # 7. question_log
    create table(:question_log) do
      add :question, :text, null: false
      add :question_embedding, :binary
      add :tier_reached, :integer, null: false
      add :candidate_chunk_ids, :text
      add :resolved_at, :utc_datetime
      add :resolved_qa_id, references(:qa_pairs, on_delete: :nilify_all)
      add :asked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:question_log, [:tier_reached, :resolved_at])

    # 8. doc_summaries
    create table(:doc_summaries) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :scope, :string, default: "document", null: false
      add :heading, :string
      add :summary, :text, null: false
      add :source_hashes, :text
      add :status, :string, default: "active", null: false
      add :generated_by, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:doc_summaries, [:document_id, :status])

    # 9. extractions
    create table(:extractions) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :chunk_id, references(:chunks, on_delete: :nilify_all)
      add :key, :string, null: false
      add :value, :string, null: false
      add :value_type, :string, default: "text", null: false
      add :status, :string, default: "active", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:extractions, [:document_id, :status])
    create index(:extractions, [:key])

    # 10. batch_runs
    create table(:batch_runs) do
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :status, :string, default: "running", null: false
      add :model_used, :string
      add :chunks_processed, :integer, default: 0, null: false
      add :qa_generated, :integer, default: 0, null: false
      add :qa_invalidated, :integer, default: 0, null: false
      add :questions_resolved, :integer, default: 0, null: false
      add :queue_remaining, :integer, default: 0, null: false
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:batch_runs, [:status, :started_at])

    # 11. batch_phase_stats
    create table(:batch_phase_stats) do
      add :batch_run_id, references(:batch_runs, on_delete: :delete_all), null: false
      add :phase_name, :string, null: false
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :duration_seconds, :integer
      add :items_count, :integer, default: 0, null: false
      add :status, :string, default: "completed", null: false

      timestamps(type: :utc_datetime)
    end

    create index(:batch_phase_stats, [:batch_run_id])

    # 12. Virtual Tables (sqlite-vec & FTS5)
    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_qa_pairs USING vec0(
      qa_pair_id INTEGER PRIMARY KEY,
      question_embedding float[1024] distance_metric=cosine
    );
    """

    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
      chunk_id INTEGER PRIMARY KEY,
      embedding float[1024] distance_metric=cosine
    );
    """

    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
      content,
      heading,
      content=chunks,
      content_rowid=id,
      tokenize='trigram'
    );
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS chunks_fts;"
    execute "DROP TABLE IF EXISTS vec_chunks;"
    execute "DROP TABLE IF EXISTS vec_qa_pairs;"

    drop table(:batch_phase_stats)
    drop table(:batch_runs)
    drop table(:extractions)
    drop table(:doc_summaries)
    drop table(:question_log)
    drop table(:answer_cache)
    drop table(:qa_pairs)
    drop table(:chunks)
    drop table(:documents)
    drop table(:google_accounts)
    drop table(:settings)
  end
end
