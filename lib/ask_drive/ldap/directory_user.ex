defmodule AskDrive.Ldap.DirectoryUser do
  @moduledoc "One person of the directory's list fetched every night (spec F-1313)."
  use Ecto.Schema

  schema "directory_users" do
    field :email, :string
    field :name, :string
    field :inserted_at, :utc_datetime
  end
end
