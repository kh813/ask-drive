defmodule AskDrive.Encrypted.Binary do
  @moduledoc """
  Custom Ecto.Type for AES-256-GCM authenticated encryption of string/binary fields.
  Storage format: <<iv::12-bytes, tag::16-bytes, ciphertext::binary>>
  """
  use Ecto.Type

  @iv_len 12
  @tag_len 16

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump(plaintext) when is_binary(plaintext) do
    key = get_encryption_key!()
    iv = :crypto.strong_rand_bytes(@iv_len)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "", @tag_len, true) do
      {ciphertext, tag} ->
        {:ok, <<iv::binary-size(@iv_len), tag::binary-size(@tag_len), ciphertext::binary>>}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  @impl true
  def load(nil), do: {:ok, nil}

  def load(<<iv::binary-size(@iv_len), tag::binary-size(@tag_len), ciphertext::binary>>) do
    key = get_encryption_key!()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) ->
        {:ok, plaintext}

      :error ->
        :error
    end
  rescue
    _ -> :error
  end

  def load(_), do: :error

  @doc """
  Retrieves the 32-byte (256-bit) encryption key from configuration or environment variable.
  If not set in dev/test, uses a deterministic fallback key for testing.
  """
  def get_encryption_key! do
    key =
      Application.get_env(:ask_drive, :encryption_key) ||
        System.get_env("ASK_DRIVE_ENCRYPTION_KEY")

    case key do
      nil ->
        if Mix.env() in [:dev, :test] do
          # 32-byte default key for dev/test
          :crypto.hash(:sha256, "ask_drive_dev_test_fallback_key")
        else
          raise "ASK_DRIVE_ENCRYPTION_KEY is required in production"
        end

      raw when is_binary(raw) ->
        decode_key(raw)
    end
  end

  defp decode_key(raw) do
    case Base.decode64(raw) do
      {:ok, decoded} when byte_size(decoded) == 32 ->
        decoded

      _ when byte_size(raw) == 32 ->
        raw

      _ ->
        # Derive 32 bytes via SHA-256 if key format is arbitrary string
        :crypto.hash(:sha256, raw)
    end
  end
end
