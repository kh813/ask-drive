defmodule AskDrive.Repo.Migrations.AddPageToChunksAndIndexVersion do
  use Ecto.Migration

  def change do
    alter table(:chunks) do
      # PDF page the chunk starts on (spec F-411); nil for formats without pages.
      add :page, :integer
    end

    alter table(:documents) do
      # Version of the extraction/chunking pipeline that indexed this document. When the
      # pipeline changes what it stores (e.g. page numbers), bumping the code's version makes
      # sync re-index files even though Drive reports them unchanged (spec F-337).
      add :index_version, :integer, default: 1, null: false
    end
  end
end
