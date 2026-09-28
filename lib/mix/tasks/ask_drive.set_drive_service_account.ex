defmodule Mix.Tasks.AskDrive.SetDriveServiceAccount do
  @shortdoc "Configures Drive sync to use a Google Service Account JSON key"

  @moduledoc """
  Sets the Google Service Account used for Drive sync (spec 6.1.1), without going through
  the admin web UI.

      mix ask_drive.set_drive_service_account /path/to/service-account-key.json
      mix ask_drive.set_drive_service_account          # auto-detects a conventional filename,
                                                        # or falls back to pasting the JSON

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

  When called with no argument, this also looks for a handful of conventional filenames
  (`credential.json`, `credentials.json`, `service-account.json`, `service-account-key.json`)
  in the current directory before falling back to the paste prompt — so simply saving the
  downloaded key under one of those names and re-running the same command with no argument
  picks it up automatically.

  ## Domain-wide delegation

      mix ask_drive.set_drive_service_account key.json --subject sync@example.com
      mix ask_drive.set_drive_service_account --subject sync@example.com   # keep stored key
      mix ask_drive.set_drive_service_account --subject ""                 # stop delegating

  When the target folder lives in a shared drive limited to members of the organization,
  the service account (always an outsider) cannot be added to it. `--subject` names the
  Workspace user to act as instead; a super admin must first grant the service account's
  `client_id` domain-wide delegation for `drive.readonly` (spec F-121). With `--subject` and
  no path, an already stored key is kept and only the subject changes.

  This switches `drive_auth_mode` to `"service_account"`. The existing OAuth connection (if
  any) is left in place and can be switched back to from the admin screen at any time.
  """
  use Mix.Task

  alias AskDrive.Drive.ServiceAccount
  alias AskDrive.Settings

  @conventional_filenames ~w(
    credential.json
    credentials.json
    service-account.json
    service-account-key.json
  )

  @impl Mix.Task
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [subject: :string])
    subject = Keyword.get(opts, :subject)

    AskDrive.CliTask.run(fn -> run_task(rest, subject) end)
  end

  # --subject alone with a key already stored: change only who is impersonated.
  defp run_task([], subject) when is_binary(subject) do
    case Settings.get_setting!() do
      %{drive_service_account_json: json} when is_binary(json) and json != "" ->
        apply_json(json, subject)

      _ ->
        run_file_or_paste([], subject)
    end
  end

  defp run_task(args, subject), do: run_file_or_paste(args, subject)

  defp run_file_or_paste([], subject) do
    case find_conventional_file() do
      {:ok, path} ->
        Mix.shell().info("#{path} を検出しました。このファイルを使用します。\n")
        apply_json(File.read!(path), subject)

      :none ->
        run_pasted(subject)
    end
  end

  defp run_file_or_paste(["-"], subject), do: run_pasted(subject)

  defp run_file_or_paste([path], subject) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> apply_json(content, subject)
        {:error, reason} -> Mix.raise("ファイルを読み込めません (#{path}): #{:file.format_error(reason)}")
      end
    else
      Mix.shell().info("指定されたファイルが見つかりません: #{path}\n代わりに JSON の中身を貼り付けます。\n")
      run_pasted(subject)
    end
  end

  defp run_file_or_paste(_args, _subject) do
    Mix.raise("""
    使用方法:
      mix ask_drive.set_drive_service_account <path-to-key.json> [--subject user@example.com]
      mix ask_drive.set_drive_service_account [--subject user@example.com]   # JSON を対話的に貼り付ける
    """)
  end

  # Looks for one of the conventional filenames in the current directory (where `mix` is
  # invoked from — the AskDrive install root, since app.sh always `cd`s there first).
  # Ambiguous when more than one candidate exists: guessing wrong here means silently
  # syncing from the wrong Drive folder, so that case asks for an explicit path instead of
  # picking one.
  defp find_conventional_file do
    case Enum.filter(@conventional_filenames, &File.exists?/1) do
      [path] -> {:ok, path}
      [] -> :none
      multiple -> Mix.raise("複数の候補が見つかりました: #{Enum.join(multiple, ", ")}\nパスを明示的に指定してください。")
    end
  end

  defp run_pasted(subject) do
    Mix.shell().info("""
    Google Cloud Console でダウンロードしたサービスアカウントの JSON キーの中身を
    そのまま貼り付けてください（コピー＆ペーストで構いません）。
    貼り付け終わったら、空行を1つ入力するか Ctrl+D を押して確定します。
    """)

    read_pasted_json()
    |> String.trim()
    |> case do
      "" -> Mix.raise("何も入力されませんでした。中断します。")
      json -> apply_json(json, subject)
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

  defp apply_json(json, subject) do
    with {:ok, account} <- ServiceAccount.parse(json),
         {:ok, setting} <- save(json, subject) do
      Mix.shell().info("""
      サービスアカウント認証を設定しました（drive_auth_mode = service_account）。
      サービスアカウントのメールアドレス: #{account.client_email}
      """)

      print_next_steps(account, setting.drive_impersonate_email)
    else
      {:error, reason} -> Mix.raise(format_error(reason))
    end
  end

  defp save(json, subject) do
    attrs = %{drive_auth_mode: "service_account", drive_service_account_json: json}
    # nil = option not given (keep the current subject); "" = explicitly stop delegating.
    attrs = if is_nil(subject), do: attrs, else: Map.put(attrs, :drive_impersonate_email, subject)

    Settings.get_setting!()
    |> Settings.update_setting(attrs)
  end

  defp print_next_steps(account, subject) when is_binary(subject) and subject != "" do
    Mix.shell().info("""
    ドメイン全体の委任: #{subject} としてアクセスします。

    Google 管理コンソール →「セキュリティ」→「API の制御」→「ドメイン全体の委任」で、
    次の設定が登録されている必要があります（特権管理者の作業です）:
      クライアント ID: #{account.client_id || "(JSON キーの client_id)"}
      OAuth スコープ : https://www.googleapis.com/auth/drive.readonly

    #{subject} には同期対象のフォルダ（または共有ドライブ）の閲覧権限が必要です。
    """)
  end

  defp print_next_steps(_account, _subject) do
    Mix.shell().info("""
    このアドレスを、同期対象の Google Drive フォルダに閲覧者として共有してください。
    未共有の場合、夜間バッチはフォルダを読み取れず失敗します。
    社内限定の共有ドライブで共有できない場合は --subject でドメイン全体の委任を使ってください。
    """)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%Ecto.Changeset{} = changeset), do: "保存に失敗しました: #{inspect(changeset.errors)}"
  defp format_error(reason), do: "設定できませんでした: #{inspect(reason)}"
end
