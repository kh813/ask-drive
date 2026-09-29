defmodule AskDrive.Accounts.AppAdmin do
  @moduledoc """
  Maps a user to a specific app slug they are authorized to administer (spec F-1110).
  Lives in the platform database.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_admins" do
    belongs_to :user, AskDrive.Accounts.User
    field :app_slug, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(app_admin, attrs) do
    app_admin
    |> cast(attrs, [:user_id, :app_slug])
    |> validate_required([:user_id, :app_slug])
    |> update_change(:app_slug, &(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> unique_constraint([:user_id, :app_slug])
  end
end
