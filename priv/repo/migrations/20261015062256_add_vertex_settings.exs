defmodule AskDrive.Repo.Migrations.AddVertexSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Google Agent Platform (formerly Vertex AI) with an API key (spec F-835): the key
      # (encrypted like the other API keys), and optionally the Google Cloud project and
      # location; without a project the global endpoint is used.
      add :vertex_api_key, :binary
      add :vertex_project, :string
      add :vertex_location, :string
    end
  end
end
