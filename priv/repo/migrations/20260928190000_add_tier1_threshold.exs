defmodule AskDrive.Repo.Migrations.AddTier1Threshold do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Cosine similarity a question must reach against a pre-generated QA question to be
      # answered with that QA (Tier 1, spec 6.4.1). Answering read a nonexistent
      # :tier1_threshold and fell back to similarity_threshold (0.65), so loosely related
      # questions got a canned answer instead of reaching the excerpt/summary tier.
      add :tier1_threshold, :float, default: 0.9, null: false
    end
  end
end
