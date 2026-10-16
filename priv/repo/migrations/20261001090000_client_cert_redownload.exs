defmodule AskDrive.Repo.Migrations.ClientCertRedownload do
  use Ecto.Migration

  def change do
    # Issue options and re-download (spec F-1409): the .p12 and its password are kept,
    # encrypted, so an administrator can hand the same certificate out again
    alter table(:client_certs) do
      add :label, :string
      add :p12, :binary
      add :password, :binary
    end
  end
end
