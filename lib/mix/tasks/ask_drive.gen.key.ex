defmodule Mix.Tasks.AskDrive.Gen.Key do
  @moduledoc """
  Generates a 256-bit (32-byte) AES encryption key encoded in Base64 for ASK_DRIVE_ENCRYPTION_KEY.

  ## Examples

      $ mix ask_drive.gen.key
  """
  use Mix.Task

  @shortdoc "Generates an encryption key for AskDrive"

  @impl Mix.Task
  def run(_args) do
    key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    Mix.shell().info(key)
  end
end
