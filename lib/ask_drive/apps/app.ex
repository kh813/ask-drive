defmodule AskDrive.Apps.App do
  @moduledoc "One AskDrive app on the platform (spec 6.11)."
  use Ecto.Schema
  import Ecto.Changeset

  # Paths the router already uses (or may use) at the top level
  @reserved ~w(admin auth login logout dev assets images fonts live phoenix api health
               favicon.ico robots.txt static uploads apps new settings)

  schema "apps" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :db_path, :string
    field :primary, :boolean, default: false
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def reserved_slugs, do: @reserved

  @doc false
  def changeset(app, attrs) do
    app
    |> cast(attrs, [:slug, :name, :description, :position])
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$|^[a-z0-9]$/,
      message:
        "must use lowercase letters, digits and hyphens (starting and ending with a letter or digit, up to 32 characters)"
    )
    |> validate_exclusion(:slug, @reserved, message: "is reserved for the system")
    |> validate_length(:name, max: 80)
    |> unique_constraint(:slug, message: "is already in use")
  end
end
