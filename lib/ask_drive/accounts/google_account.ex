defmodule AskDrive.Accounts.GoogleAccount do
  use Ecto.Schema
  import Ecto.Changeset

  schema "google_accounts" do
    field :email, :string
    field :access_token, :binary
    field :refresh_token, :binary
    field :token_expires_at, :utc_datetime
    field :scope, :string
    field :status, :string, default: "connected"

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:email, :access_token, :refresh_token, :token_expires_at, :scope, :status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ["connected", "disconnected", "invalid_grant", "expired"])
  end
end
