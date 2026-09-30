defmodule AskDriveWeb.ClientCertController do
  @moduledoc "Hands out an issued client certificate (.p12) once (spec 6.14)."
  use AskDriveWeb, :controller

  def download(conn, %{"token" => token}) do
    case AskDrive.ClientCerts.take_download(token) do
      {:ok, p12, filename} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_download({:binary, p12}, filename: filename, content_type: "application/x-pkcs12")

      :error ->
        conn
        |> put_flash(:error, "ダウンロードの期限が切れたか、すでにダウンロード済みです。証明書を発行し直してください。")
        |> redirect(to: ~p"/admin?tab=settings")
    end
  end
end
