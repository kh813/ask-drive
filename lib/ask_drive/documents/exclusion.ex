defmodule AskDrive.Documents.Exclusion do
  @moduledoc """
  A Drive file or folder the nightly batch leaves out of the index (spec F-358). A folder
  takes everything below it. `source` is "admin" (set and removed on the documents tab) or
  "system" (a file AskDrive writes itself, such as an exported FAQ sheet; never removable).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(file folder)
  @sources ~w(admin system)

  schema "drive_exclusions" do
    field :drive_id, :string
    field :kind, :string
    field :name, :string
    field :path, :string
    field :source, :string, default: "admin"
    field :excluded_by, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(exclusion, attrs) do
    exclusion
    |> cast(attrs, [:drive_id, :kind, :name, :path, :source, :excluded_by])
    |> validate_required([:drive_id, :kind, :source])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> unique_constraint(:drive_id)
  end
end
