defmodule AskDrive.ClientCerts.Group do
  @moduledoc "A group (a department, say) sharing one client certificate (spec 6.14)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "client_cert_groups" do
    field :name, :string
    has_many :certs, AskDrive.ClientCerts.Cert
    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name], message: "グループ名を入力してください")
    |> validate_length(:name, max: 60)
    |> validate_format(:name, ~r{^[^/\\\\=,+"<>;#]+$}, message: "に使えない文字が含まれています")
    |> unique_constraint(:name, message: "は既にあります")
  end
end
