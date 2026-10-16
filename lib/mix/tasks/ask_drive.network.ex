defmodule Mix.Tasks.AskDrive.Network do
  @shortdoc "Shows the listening ports / trusted proxies, or undoes them (lockout recovery)"

  @moduledoc """
  The ports and trusted reverse proxies of spec F-1013 from the server's command line, for
  when a change on the admin screen locked everyone out.

      mix ask_drive.network status
      mix ask_drive.network proxy-off     # forget the proxies: plain HTTP redirects again
      mix ask_drive.network ports-reset   # HTTP 4000 / HTTPS 4443 (applies on restart)
      mix ask_drive.network gateway-off   # stop requiring the API gateway's header (F-1014)

  The running service re-reads the proxies and the gateway settings when their files change,
  so `proxy-off` and `gateway-off` apply at once; the ports need a restart (`./app.sh network ports-reset` does it).
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
    API ゲートウェイ: #{gateway_status()}
    設定ファイル: #{Network.file()}・#{AskDrive.Gateway.file()}
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

  defp run_task(["gateway-off"]) do
    :ok = AskDrive.Gateway.disable!()
    Mix.shell().info("API ゲートウェイの確認を無効にしました（ゲートウェイを通らない直接アクセスも受け付けます）。")
  end

  defp run_task(_),
    do: Mix.raise("使用方法: mix ask_drive.network status | proxy-off | ports-reset | gateway-off")

  defp gateway_status do
    g = AskDrive.Gateway.settings()

    if AskDrive.Gateway.enabled?() do
      direct = if g.direct_ranges == [], do: "なし", else: Enum.join(g.direct_ranges, ", ")
      "有効（公開 URL: #{g.public_url}、直接アクセスを許可: サーバー自身・#{direct}）"
    else
      if g.secret, do: "無効（設定は保存済み）", else: "無効"
    end
  end
end
