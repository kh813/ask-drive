defmodule Mix.Tasks.AskDrive.Mtls do
  @shortdoc "Shows or switches off access restricted to devices with a client certificate"

  @moduledoc """
  The client-certificate restriction of spec 6.14 from the server's command line, for when
  it locked everyone out.

      mix ask_drive.mtls status
      mix ask_drive.mtls off       # everyone gets in again (at once, no restart needed)
      mix ask_drive.mtls monitor | enforce
      mix ask_drive.mtls issue <group> <file.p12> [--expires YYYY-MM-DD] [--label TEXT] [--password TEXT]
                                    # issue from the server (prints the password)

  The running service re-reads the mode when the file changes, so `off` applies at once;
  the HTTPS listener stops asking for certificates at the next restart.
  """
  use Mix.Task
  alias AskDrive.ClientCerts

  @impl Mix.Task
  def run(args), do: AskDrive.CliTask.run(fn -> run_task(args) end)

  defp run_task(["status"]) do
    groups = ClientCerts.list_groups()
    active = for g <- groups, c <- g.certs, is_nil(c.revoked_at), do: c

    Mix.shell().info("""
    端末の電子証明書によるアクセス制限: #{label(ClientCerts.mode())}
    社内 LAN（証明書不要）: #{if ClientCerts.lan_ranges() == [], do: "なし", else: Enum.join(ClientCerts.lan_ranges(), ", ")}
    グループ: #{length(groups)} 件・有効な証明書: #{length(active)} 件
    認証局: #{if File.exists?(ClientCerts.ca_cert_path()), do: ClientCerts.ca_cert_path(), else: "未作成"}
    """)
  end

  defp run_task(["off"]) do
    {:ok, _} = ClientCerts.set_mode("off")
    Mix.shell().info("端末の電子証明書によるアクセス制限を無効にしました（すぐに反映されます。./app.sh restart で証明書の要求も止まります）。")
  end

  defp run_task([mode]) when mode in ["monitor", "enforce"] do
    {:ok, _} = ClientCerts.set_mode(mode)
    Mix.shell().info("#{label(mode)}にしました（証明書の要求を始めるには ./app.sh restart が必要です）。")
  end

  defp run_task(["issue" | rest]) do
    {opts, args, _} =
      OptionParser.parse(rest, strict: [expires: :string, label: :string, password: :string])

    case args do
      [name, file] -> issue(name, file, opts)
      _ -> run_task([])
    end
  end

  defp run_task(_),
    do:
      Mix.raise(
        "使用方法: mix ask_drive.mtls status | off | monitor | enforce | issue <グループ> <ファイル.p12> [--expires YYYY-MM-DD] [--label メモ] [--password パスワード]"
      )

  defp issue(name, file, opts) do
    group =
      Enum.find(ClientCerts.list_groups(), &(&1.name == name)) ||
        elem(ClientCerts.create_group(name), 1)

    params = %{expires_on: opts[:expires], label: opts[:label], password: opts[:password]}

    case ClientCerts.issue(group, "cli", params) do
      {:ok, issued} ->
        File.write!(file, issued.p12)
        File.chmod!(file, 0o600)

        Mix.shell().info("""
        #{file} に発行しました（表示名: #{ClientCerts.display_name(group.name, issued.cert.label)}、有効期限: #{AskDrive.Clock.format(issued.cert.not_after, "%Y-%m-%d")}）。
        パスワード: #{issued.password}
        """)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp label("enforce"), do: "強制"
  defp label("monitor"), do: "監視"
  defp label(_), do: "無効"
end
