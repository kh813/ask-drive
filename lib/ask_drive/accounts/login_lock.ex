defmodule AskDrive.Accounts.LoginLock do
  @moduledoc "An active lockout of password sign-in (spec F-1305): an account or an environment."
  use Ecto.Schema

  schema "login_locks" do
    # "account" (key = e-mail) or "env" (key = connection environment)
    field :scope, :string
    field :key, :string
    field :email, :string
    field :ip, :string
    field :user_agent, :string
    field :locked_until, :utc_datetime
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
