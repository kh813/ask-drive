defmodule Mix.Tasks.AskDrive.Network do
  @shortdoc "Shows the listening ports / trusted proxies, or undoes them (lockout recovery)"

  @moduledoc """
  The ports and trusted reverse proxies of spec F-1013 from the server's command line, for
  when a change on the admin screen locked everyone out.

      mix ask_drive.network status
      mix ask_drive.network proxy-off     # forget the proxies: plain HTTP redirects again
      mix ask_drive.network ports-reset   # HTTP 4000 / HTTPS 4443 (applies on restart)

  The running service re-reads the proxies when the file changes, so `proxy-off` applies
  at once; the ports need a restart (`./app.sh network ports-reset` does it).
  """
  use Mix.Task
  alias AskDrive.Network

  @impl Mix.Task
  def run(args), do: AskDrive.CliTask.run(fn -> run_task(args) end)

  defp run_task(["status"]) do
    s = Network.settings()

    Mix.shell().info("""
    HTTPS: #{if AskDrive.SSL.enabled?(), do: "ポート #{s.https_port}", else: "無効（ASK_DRIVE_SSL=false）"}
    HTTP: ポート #{s.http_port}（#{if AskDrive.SSL.enabled?(), do: "HTTPS へ転送。下記プロキシからは HTTP のまま受け付け", else: "HTTP で応答"}）
    HTTP を受け付けるリバースプロキシ: #{if s.trusted_proxies == [], do: "なし", else: Enum.join(s.trusted_proxies, ", ")}
    設定ファイル: #{Network.file()}
    """)
  end

  defp run_task(["proxy-off"]) do
    :ok = Network.clear_proxies!()
    Mix.shell().info("リバースプロキシの指定を解除しました（HTTP はすべて HTTPS へ転送されます）。")
  end

  defp run_task(["ports-reset"]) do
    :ok = Network.reset_ports!()
    s = Network.settings()
    Mix.shell().info("ポートを HTTP #{s.http_port} / HTTPS #{s.https_port} に戻しました（再起動で反映されます）。")
  end

  defp run_task(_), do: Mix.raise("使用方法: mix ask_drive.network status | proxy-off | ports-reset")
end
