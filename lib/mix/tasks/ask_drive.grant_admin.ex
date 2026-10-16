defmodule Mix.Tasks.AskDrive.GrantAdmin do
  @shortdoc "Allows an email address to elevate to administrator"

  @moduledoc """
  Marks a user as allowed to elevate to administrator, creating the record if they have
  never signed in.

      mix ask_drive.grant_admin someone@company.com

  This is the recovery path of spec 6.9 F-920: the admin screen protects against removing
  the last eligible account, but a misconfigured `ASK_DRIVE_ADMIN_EMAILS` or a restored
  database can still leave nobody able to reach it.

  It grants no rights on its own. The account still has to sign in with Google *and* enter
  the administrator password before anything privileged happens.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    AskDrive.CliTask.run(fn -> run_task(args) end)
  end

  defp run_task([email]) do
    case AskDrive.Accounts.grant_admin(email) do
      {:ok, user} ->
        Mix.shell().info("""
        #{user.email} を全体管理者にしました。
        ログインしたうえで、ヘッダーの「全体管理」から本人確認をすると入れます。
        """)

      {:error, changeset} ->
        Mix.raise("昇格の許可を付与できませんでした: #{inspect(changeset.errors)}")
    end
  end

  defp run_task(_args) do
    Mix.raise("使用方法: mix ask_drive.grant_admin <email>")
  end
end
