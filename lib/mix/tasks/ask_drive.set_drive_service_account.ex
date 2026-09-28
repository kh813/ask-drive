defmodule Mix.Tasks.AskDrive.SetDriveServiceAccount do
  @shortdoc "Configures Drive sync to use a Google Service Account JSON key"

  @moduledoc """
  Sets the Google Service Account used for Drive sync (spec 6.1.1), without going through
  the admin web UI.

      mix ask_drive.set_drive_service_account /path/to/service-account-key.json

  This is the recovery path for a chicken-and-egg problem: the settings screen that
  configures Drive sync sits behind Google sign-in and administrator elevation, but if
  nobody can complete that sign-in yet (broken OAuth redirect_uri, no admin password set,
  etc.), there is no way to reach it. This task writes directly to the database instead.

  The file must be the JSON key downloaded from Google Cloud Console for a service account
  (Console -> IAM & Admin -> Service Accounts -> that account -> Keys -> Add key -> JSON).
  Before this will actually work, share the target Drive folder with the service account's
  email address (the `client_email` field in the file) as you would with any other Google
  user.

  This switches `drive_auth_mode` to `"service_account"`. The existing OAuth connection (if
  any) is left in place and can be switched back to from the admin screen at any time.
  """
  use Mix.Task

  alias AskDrive.Drive.ServiceAccount
  alias AskDrive.Settings

  @requirements ["app.start"]

  @impl Mix.Task
  def run([path]) do
    with {:ok, json} <- read_file(path),
         {:ok, account} <- ServiceAccount.parse(json),
         {:ok, _setting} <- save(json) do
      Mix.shell().info("""
      サービスアカウント認証を設定しました（drive_auth_mode = service_account）。
      サービスアカウントのメールアドレス: #{account.client_email}

      このアドレスを、同期対象の Google Drive フォルダに閲覧者として共有してください。
      未共有の場合、夜間バッチはフォルダを読み取れず失敗します。
      """)
    else
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  end

  def run(_args) do
    Mix.raise("使用方法: mix ask_drive.set_drive_service_account <path-to-key.json>")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "ファイルを読み込めません (#{path}): #{:file.format_error(reason)}"}
    end
  end

  defp save(json) do
    Settings.get_setting!()
    |> Settings.update_setting(%{
      drive_auth_mode: "service_account",
      drive_service_account_json: json
    })
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%Ecto.Changeset{} = changeset), do: "保存に失敗しました: #{inspect(changeset.errors)}"
  defp format_error(reason), do: "設定できませんでした: #{inspect(reason)}"
end
