defmodule AskDrive.Repo.Migrations.AddMd5ChecksumToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      # Drive's md5Checksum (binary files only; Google Docs/Sheets/Slides have none).
      # Lets sync skip a file whose modifiedTime moved but whose bytes did not (spec F-334).
      add :md5_checksum, :string
    end
  end
end
