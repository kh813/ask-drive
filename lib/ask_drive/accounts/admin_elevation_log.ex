defmodule AskDrive.Accounts.AdminElevationLog do
  @moduledoc """
  Audit trail for administrator elevation (spec 6.9.3 / 7.1.2).

  Rows are append-only: nothing in the application updates or deletes them, and deleting a
  user nullifies the reference rather than removing the record, so "which account elevated"
  stays answerable afterwards.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias AskDrive.Accounts.User

  @events ~w(granted denied locked_out released expired password_set password_changed password_reset
              app_admin_added app_admin_removed)

  schema "admin_elevation_logs" do
    field :email, :string
    field :event, :string
    field :ip_address, :string
    field :user_agent, :string
    field :occurred_at, :utc_datetime
    # the app a row is about (spec F-1113); nil = the platform
    field :app_slug, :string
    # whose assignment an app_admin_added / app_admin_removed row is about (F-1114)
    field :target_email, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc "Recognised audit events."
  def events, do: @events

  @doc "Japanese label for the admin dashboard."
  def label("granted"), do: "昇格"
  def label("denied"), do: "失敗（パスワード不一致など）"
  def label("locked_out"), do: "ロックアウト"
  def label("released"), do: "解除"
  def label("expired"), do: "期限切れ"
  def label("password_set"), do: "パスワード初回設定"
  def label("password_changed"), do: "パスワード変更"
  def label("password_reset"), do: "パスワードのリセット（全体管理者）"
  def label("app_admin_added"), do: "窓口管理者を追加"
  def label("app_admin_removed"), do: "窓口管理者から削除"
  def label(other), do: other

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :user_id,
      :email,
      :event,
      :ip_address,
      :user_agent,
      :occurred_at,
      :app_slug,
      :target_email
    ])
    |> validate_required([:email, :event, :occurred_at])
    |> validate_inclusion(:event, @events)
    # A long User-Agent must never be the reason an audit write fails.
    |> update_change(:user_agent, &truncate(&1, 255))
    |> update_change(:ip_address, &truncate(&1, 64))
  end

  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp truncate(value, _max), do: value
end
