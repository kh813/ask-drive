defmodule AskDriveWeb.Plugs.ClientCertGate do
  @moduledoc """
  The entrance for devices with a certificate issued by AskDrive (spec 6.14), before the
  login page. `monitor` records who comes with and without one; `enforce` answers a
  request without a valid certificate with an explanation page (403). The server itself
  (localhost) always gets in, as a way back.
  """
  import Plug.Conn
  alias AskDrive.ClientCerts

  def init(opts), do: opts

  def call(conn, _opts) do
    case ClientCerts.mode() do
      "off" -> conn
      mode -> gate(conn, mode)
    end
  end

  defp gate(conn, mode) do
    result = conn |> get_peer_data() |> Map.get(:ssl_cert) |> ClientCerts.check()
    user = conn.assigns[:current_user]

    case result do
      {:ok, cert} ->
        ClientCerts.seen(cert)
        if user, do: ClientCerts.note_user(user, true)
        assign(conn, :client_cert, cert)

      problem ->
        if user, do: ClientCerts.note_user(user, false)

        cond do
          mode == "monitor" -> conn
          loopback?(conn) -> conn
          true -> refuse(conn, problem)
        end
    end
  end

  defp loopback?(conn) do
    case get_peer_data(conn).address do
      {127, _, _, _} -> true
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, _} -> true
      _ -> false
    end
  end

  defp refuse(conn, problem) do
    reason =
      case problem do
        :none -> "この端末（ブラウザ）には、AskDrive の電子証明書がインストールされていません。"
        :revoked -> "この端末の電子証明書は失効しています。"
        :expired -> "この端末の電子証明書は有効期限が切れています。"
        _ -> "この端末の電子証明書は、この AskDrive が発行したものではありません。"
      end

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(403, page(reason))
    |> halt()
  end

  defp page(reason) do
    """
    <!DOCTYPE html>
    <html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>AskDrive - アクセスできません</title>
    <link rel="icon" href="/favicon.svg?v=2" type="image/svg+xml">
    <style>
      body{font-family:system-ui,-apple-system,"Hiragino Sans","Noto Sans JP",sans-serif;background:#f4f4f5;color:#27272a;margin:0;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:16px}
      main{background:#fff;border:1px solid #e4e4e7;border-radius:16px;max-width:520px;padding:32px;box-shadow:0 1px 2px rgba(0,0,0,.05)}
      h1{font-size:18px;margin:0 0 12px} p,li{font-size:14px;line-height:1.7;margin:8px 0} .reason{color:#b91c1c}
      .badge{width:40px;height:40px;border-radius:10px;background:#4f46e5;color:#fff;font-weight:700;display:flex;align-items:center;justify-content:center;margin-bottom:16px}
    </style></head>
    <body><main>
      <div class="badge">AD</div>
      <h1>この端末からは AskDrive にアクセスできません</h1>
      <p class="reason">#{reason}</p>
      <p>AskDrive は、管理者が配布した電子証明書をインストールした端末からだけ利用できます。</p>
      <ul>
        <li>配布された証明書ファイル（.p12）を開き、案内されたパスワードでインストールしてください。</li>
        <li>インストール後はブラウザを再起動し、証明書の選択を求められたら「AskDrive」の証明書を選んでください。</li>
        <li>証明書をお持ちでない場合や、インストールしても表示が変わらない場合は、管理者に連絡してください。</li>
      </ul>
    </main></body></html>
    """
  end
end
