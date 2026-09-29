defmodule Mix.Tasks.AskDrive.Auth do
  @shortdoc "Shows or switches required login and LDAP sign-in (lockout recovery)"

  @moduledoc """
  Required login from the server's command line (spec F-1308), for when the admin screen
  can't be reached — e.g. LDAP stopped working after login was switched on.

      mix ask_drive.auth status
      mix ask_drive.auth disable            # back to guest (POC): no login anywhere
      mix ask_drive.auth enable [email ...] # login required; emails = administrator accounts
      mix ask_drive.auth ldap off|on        # LDAP sign-in off / on

  The running service reads the setting on every request, so a change applies at once.
  `ASK_DRIVE_DISABLE_AUTH` in `.env.prod`, when present, overrides the setting.
  """
  use Mix.Task

  alias AskDrive.{Accounts, Ldap, Settings}

  @impl Mix.Task
  def run(args), do: AskDrive.CliTask.run(fn -> run_task(args) end)

  defp run_task(["status"]), do: status()

  defp run_task(["disable"]) do
    {:ok, _} = Settings.set_auth_required(false)
    Mix.shell().info("ログイン認証を無効にしました（ゲスト・POC: 誰でもログインなしでチャットと管理画面を使えます）。")
    warn_env()
  end

  defp run_task(["enable" | rest]) do
    setting = Settings.platform_setting!()

    unless Ldap.enabled?(setting) or AskDrive.Drive.OAuth.get_client_id() != "" do
      Mix.raise("ログインの方法がありません。Google Secure LDAP または Google ログイン（OAuth）を設定してください。")
    end

    Enum.each(rest, fn email -> {:ok, _} = Accounts.grant_admin(email) end)

    if Accounts.count_eligible_admins() == 0 do
      Mix.raise("管理者に昇格できるアカウントがありません。mix ask_drive.auth enable <email> で指定してください。")
    end

    {:ok, _} = Settings.set_auth_required(true)
    Mix.shell().info("ログイン認証を有効にしました。")
    warn_env()
  end

  defp run_task(["ldap", state]) when state in ["on", "off"] do
    setting = Settings.platform_setting!()

    case Settings.update_ldap(setting, %{"ldap_enabled" => to_string(state == "on")}) do
      {:ok, _} ->
        Mix.shell().info("LDAP でのログインを#{if state == "on", do: "有効", else: "無効"}にしました。")

      {:error, changeset} ->
        Mix.raise("変更できませんでした: #{inspect(changeset.errors)}")
    end
  end

  defp run_task(_) do
    Mix.raise("使用方法: mix ask_drive.auth status | disable | enable [email ...] | ldap on|off")
  end

  defp status do
    setting = Settings.platform_setting!()
    {state, source} = AskDriveWeb.UserAuth.auth_mode()

    source_label =
      case source do
        :env -> "環境変数 ASK_DRIVE_DISABLE_AUTH で固定"
        :setting -> "設定"
        :default -> "既定（未設定）"
      end

    Mix.shell().info("""
    ログイン認証: #{if state == :enabled, do: "有効", else: "無効（ゲスト・POC）"}（#{source_label}）
    Google Secure LDAP: #{if Ldap.enabled?(setting), do: "有効 (#{setting.ldap_host || Ldap.default_host()})", else: "無効"}
    Google ログイン（OAuth）: #{if AskDrive.Drive.OAuth.get_client_id() != "", do: "設定済み", else: "未設定"}
    管理者に昇格できるアカウント: #{Accounts.count_eligible_admins()} 件
    """)
  end

  defp warn_env do
    if elem(AskDriveWeb.UserAuth.auth_mode(), 1) == :env do
      Mix.shell().error(
        "注意: .env.prod の ASK_DRIVE_DISABLE_AUTH がこの設定より優先されます。この行を削除して ./app.sh restart してください。"
      )
    end
  end
end
