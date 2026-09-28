defmodule AskDrive.Apps.App do
  @moduledoc "One AskDrive app on the platform (spec 6.11)."
  use Ecto.Schema
  import Ecto.Changeset

  # Paths the router already uses (or may use) at the top level
  @reserved ~w(admin auth login logout dev assets images fonts live phoenix api health
               favicon.ico robots.txt static uploads apps new settings)

  schema "apps" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :db_path, :string
    field :primary, :boolean, default: false
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def reserved_slugs, do: @reserved

  @doc false
  def changeset(app, attrs) do
    app
    |> cast(attrs, [:slug, :name, :description, :position])
    |> update_change(:slug, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:slug, :name])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]{0,30}[a-z0-9]$|^[a-z0-9]$/,
      message: "は英小文字・数字・ハイフンで入力してください（先頭と末尾は英数字、32 文字まで）"
    )
    |> validate_exclusion(:slug, @reserved, message: "はシステムで使用するため利用できません")
    |> validate_length(:name, max: 80)
    |> unique_constraint(:slug, message: "は既に使われています")
  end
end
