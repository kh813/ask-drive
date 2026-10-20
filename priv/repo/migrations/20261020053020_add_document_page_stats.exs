defmodule AskDrive.Repo.Migrations.AddDocumentPageStats do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      # a PDF's pages, and how many of them have (almost) no text — images only — for the
      # token efficiency score (spec 14.6, F-1410): screenshots no longer count against a
      # manual whose text is there
      add :page_count, :integer
      add :textless_pages, :integer
    end
  end
end
