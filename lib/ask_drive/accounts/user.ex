defmodule AskDrive.Accounts.User do
  @moduledoc """
  A person who signs in to AskDrive (spec 7.1.1).

  Distinct from `AskDrive.Accounts.GoogleAccount`, which is the single Drive-reading
  service account. No OAuth tokens are stored here: the authorization code exchange only
  proves identity, and the Phoenix session carries it from there.

  There is deliberately no standing admin role. `admin_eligible` says the account may
  *attempt* to enter Platform Admin (confirming it is them with their own account); whether
  it currently holds admin rights is
  session state, checked through `AskDriveWeb.UserAuth` (spec 6.9.1).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active disabled)

  schema "users" do
    field :email, :string
    field :name, :string
    field :picture_url, :string
    # client certificates (spec 6.14, monitor mode): last access with / without one
    field :client_cert_seen_at, :utc_datetime
    field :no_client_cert_seen_at, :utc_datetime
    field :admin_eligible, :boolean, default: false
    field :status, :string, default: "active"
    field :last_login_at, :utc_datetime
    field :last_elevated_at, :utc_datetime

    has_many :app_admins, AskDrive.Accounts.AppAdmin

    timestamps(type: :utc_datetime)
  end

  @doc "Valid status values."
  def statuses, do: @statuses

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :picture_url,
      :admin_eligible,
      :status,
      :last_login_at,
      :last_elevated_at
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :status])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/, message: "の形式が正しくありません")
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:email)
  end

  @doc """
  Lower-cases and trims an address so lookups are case-insensitive without needing citext,
  which SQLite does not provide.
  """
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(other), do: other

  @doc """
  Whether the account is allowed to attempt elevation. This is *not* "is an admin".
  """
  def admin_eligible?(%__MODULE__{admin_eligible: true, status: "active"}), do: true
  def admin_eligible?(_), do: false

  @doc "Whether the user may sign in at all."
  def active?(%__MODULE__{status: "active"}), do: true
  def active?(_), do: false

  @doc "Name for display, falling back to the address."
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}), do: email
end
