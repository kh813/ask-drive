defmodule AskDrive.Repo.Migrations.CreateApiUsageLogs do
  use Ecto.Migration

  def change do
    create table(:api_usage_logs) do
      add :provider, :string, null: false
      add :model, :string, null: false
      add :purpose, :string, null: false
      add :prompt_tokens, :integer, default: 0
      add :completion_tokens, :integer, default: 0
      add :total_tokens, :integer, default: 0
      add :request_bytes, :integer, default: 0
      add :latency_ms, :integer, default: 0
      add :status, :string, default: "ok", null: false
      add :error_message, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:api_usage_logs, [:inserted_at])
    create index(:api_usage_logs, [:provider, :model])
    create index(:api_usage_logs, [:status])
  end
end
