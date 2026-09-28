defmodule Mix.Tasks.AskDrive.SetDriveServiceAccount do
  @shortdoc "Configures Drive sync to use a Google Service Account JSON key"

  @moduledoc """
  Sets the Google Service Account used for Drive sync (spec 6.1.1), without going through
  the admin web UI.

      mix ask_drive.set_drive_service_account /path/to/service-account-key.json
      mix ask_drive.set_drive_service_account          # no file yet: paste the JSON instead

  This is the recovery path for a chicken-and-egg problem: the settings screen that
  configures Drive sync sits behind Google sign-in and administrator elevation, but if
  nobody can complete that sign-in yet (broken OAuth redirect_uri, no admin password set,
  etc.), there is no way to reach it. This task writes directly to the database instead.

  The private key is minted by Google when a service account key is created, so there is
  nothing here to "generate" from scratch by answering prompts. What this task interactively
  asks for instead is the JSON key's *content*, for the common case of not having saved it to
  a file on the machine running AskDrive: run with no argument, or a path that doesn't exist,
  and it prompts you to paste the whole JSON blob (finish with an empty line, or Ctrl+D).

  Either way the JSON must be the key downloaded from Google Cloud Console for a service
  account (Console -> IAM & Admin -> Service Accounts -> that account -> Keys -> Add key ->
  JSON). Before this will actually work, share the target Drive folder with the service
  account's email address (the `client_email` field) as you would with any other Google user.

  This switches `drive_auth_mode` to `"service_account"`. The existing OAuth connection (if
  any) is left in place and can be switched back to from the admin screen at any time.
  """
  use Mix.Task

  alias AskDrive.Drive.ServiceAccount
  alias AskDrive.Settings

  @impl Mix.Task
  def run(args) do
    AskDrive.CliTask.run(fn -> run_task(args) end)
  end

  defp run_task([]), do: run_pasted()
  defp run_task(["-"]), do: run_pasted()

  defp run_task([path]) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> apply_json(content)
        {:error, reason} -> Mix.raise("ファイルを読み込めません (#{path}): #{:file.format_error(reason)}")
      end
    else
      Mix.shell().info("指定されたファイルが見つかりません: #{path}\n代わりに JSON の中身を貼り付けます。\n")
      run_pasted()
    end
  end

  defp run_task(_args) do
    Mix.raise("""
    使用方法:
      mix ask_drive.set_drive_service_account <path-to-key.json>
      mix ask_drive.set_drive_service_account            # JSON を対話的に貼り付ける
    """)
  end

  defp run_pasted do
    Mix.shell().info("""
    Google Cloud Console でダウンロードしたサービスアカウントの JSON キーの中身を
    そのまま貼り付けてください（コピー＆ペーストで構いません）。
    貼り付け終わったら、空行を1つ入力するか Ctrl+D を押して確定します。
    """)

    read_pasted_json()
    |> String.trim()
    |> case do
      "" -> Mix.raise("何も入力されませんでした。中断します。")
      json -> apply_json(json)
    end
  end

  # Reads until EOF (Ctrl+D) or a blank line -- whichever a paste-then-Enter terminal
  # session produces first. A JSON object never contains a genuinely blank line once
  # `Jason.encode!/1` is the source, so this does not truncate real Google-issued keys.
  defp read_pasted_json(acc \\ []) do
    case IO.gets("") do
      :eof -> acc |> Enum.reverse() |> Enum.join()
      {:error, _reason} -> acc |> Enum.reverse() |> Enum.join()
      "\n" -> acc |> Enum.reverse() |> Enum.join()
      line -> read_pasted_json([line | acc])
    end
  end

  defp apply_json(json) do
    with {:ok, account} <- ServiceAccount.parse(json),
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
