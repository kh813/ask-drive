defmodule AskDriveWeb.ClientCertController do
  @moduledoc "Hands out an issued client certificate in the form each OS installs best (spec 6.14)."
  use AskDriveWeb, :controller

  def download(conn, %{"token" => token} = params) do
    case AskDrive.ClientCerts.take_download(token, params["format"] || "macos") do
      {:ok, body, filename, content_type} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_download({:binary, body}, filename: filename, content_type: content_type)

      :error ->
        conn
        |> put_flash(:error, "ダウンロードの期限（発行から 10 分）が切れました。証明書を発行し直してください。")
        |> redirect(to: ~p"/admin?tab=settings")
    end
  end
end
