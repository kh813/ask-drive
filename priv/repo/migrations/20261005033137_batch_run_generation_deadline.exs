defmodule AskDrive.Repo.Migrations.BatchRunGenerationDeadline do
  use Ecto.Migration

  def change do
    # When this run's QA generation is cut off (F-355): the night's cut-off, or this desk's
    # share of the time left when the nightly batch shares it between desks
    alter table(:batch_runs) do
      add :generation_deadline, :utc_datetime
    end
  end
end
