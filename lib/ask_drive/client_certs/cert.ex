defmodule AskDrive.ClientCerts.Cert do
  @moduledoc "A client certificate AskDrive issued (spec 6.14); only its identity is kept, never the key."
  use Ecto.Schema

  schema "client_certs" do
    belongs_to :group, AskDrive.ClientCerts.Group
    field :serial, :string
    field :not_before, :utc_datetime
    field :not_after, :utc_datetime
    field :issued_by, :string
    field :revoked_at, :utc_datetime
    field :revoked_by, :string
    field :last_seen_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
