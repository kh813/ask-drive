defmodule AskDrive.ClientCerts.Cert do
  @moduledoc """
  A client certificate AskDrive issued (spec 6.14). The `.p12` and its password are kept
  encrypted (AES-256-GCM, `ASK_DRIVE_ENCRYPTION_KEY`) so it can be downloaded again
  (F-1409); certificates issued before that have neither.
  """
  use Ecto.Schema

  schema "client_certs" do
    belongs_to :group, AskDrive.ClientCerts.Group
    field :serial, :string
    field :label, :string
    field :p12, AskDrive.Encrypted.Binary, redact: true
    field :password, AskDrive.Encrypted.Binary, redact: true
    # set by `AskDrive.ClientCerts.list_groups/0`: whether the .p12 is kept
    field :kept?, :boolean, virtual: true, default: false
    field :not_before, :utc_datetime
    field :not_after, :utc_datetime
    field :issued_by, :string
    field :revoked_at, :utc_datetime
    field :revoked_by, :string
    field :last_seen_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
