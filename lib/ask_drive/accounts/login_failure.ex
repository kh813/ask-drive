defmodule AskDrive.Accounts.LoginFailure do
  @moduledoc "A failed password sign-in (spec 6.13), counted for the lockout."
  use Ecto.Schema

  schema "login_failures" do
    field :email, :string
    field :ip, :string
    field :reason, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
