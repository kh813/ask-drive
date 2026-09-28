defmodule AskDrive.Repo.Migrations.EncryptGoogleClientSecret do
  @moduledoc """
  `settings.google_client_secret` was stored in plaintext. Spec 9.6 N-603 now requires it
  to be encrypted at rest alongside the provider API keys, so re-write existing rows as
  AES-256-GCM ciphertext. SQLite keeps BLOBs intact in a TEXT-affinity column, so the
  column itself does not need to change.
  """
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  alias AskDrive.Encrypted.Binary
  alias AskDrive.Repo

  def up do
    for {id, secret} <- plaintext_secrets() do
      case Binary.dump(secret) do
        {:ok, ciphertext} ->
          Repo.update_all(from(s in "settings", where: s.id == ^id),
            set: [google_client_secret: ciphertext]
          )

        :error ->
          raise """
          settings.google_client_secret の暗号化に失敗しました。
          ASK_DRIVE_ENCRYPTION_KEY が設定されているか確認してください。
          """
      end
    end
  end

  def down do
    for {id, ciphertext} <- encrypted_secrets() do
      case Binary.load(ciphertext) do
        {:ok, plaintext} ->
          Repo.update_all(from(s in "settings", where: s.id == ^id),
            set: [google_client_secret: plaintext]
          )

        :error ->
          :ok
      end
    end
  end

  # Rows written before this migration hold UTF-8 text; already-encrypted rows are binary
  # that fails `String.valid?/1`, so re-running the migration is a no-op for them.
  defp plaintext_secrets do
    "settings"
    |> select_secrets()
    |> Enum.filter(fn {_id, value} -> String.valid?(value) end)
  end

  defp encrypted_secrets do
    "settings"
    |> select_secrets()
    |> Enum.reject(fn {_id, value} -> String.valid?(value) end)
  end

  defp select_secrets(table) do
    Repo.all(
      from(s in table,
        where: not is_nil(s.google_client_secret),
        select: {s.id, s.google_client_secret}
      )
    )
  end
end
