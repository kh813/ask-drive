defmodule AskDrive.Notify.GoogleChat do
  @moduledoc """
  Messages to a Google Chat space through an incoming webhook (spec F-1507): the URL set in
  the platform's update settings. Used for update notices — when an update starts, and when
  the new version is up (or the update failed) — so whoever looks after the server learns of
  an unattended night-time update, and of a restart that never came back.

  Sending never raises: a failure is logged and returned, and the update goes on regardless.
  """
  require Logger

  alias AskDrive.Settings

  @doc "Whether a webhook is set (in `setting`, the platform's by default)."
  def configured?(setting \\ Settings.platform_setting()),
    do:
      is_binary(setting && setting.google_chat_webhook_url) and
        setting.google_chat_webhook_url != ""

  @doc "Posts `text` to the webhook: `:ok`, `{:error, message}`, or `:not_configured`."
  def send_message(text, setting \\ Settings.platform_setting()) do
    if configured?(setting) do
      opts =
        [
          url: setting.google_chat_webhook_url,
          json: %{text: text},
          receive_timeout: 10_000,
          retry: false
        ] ++ Application.get_env(:ask_drive, :notify_req_options, [])

      case Req.post(opts) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          message = "Google Chat が HTTP #{status} を返しました（#{error_detail(body)}）"
          Logger.warning("GoogleChat: #{message}")
          {:error, message}

        {:error, error} ->
          message = "Google Chat に送信できませんでした（#{Exception.message(error)}）"
          Logger.warning("GoogleChat: #{message}")
          {:error, message}
      end
    else
      :not_configured
    end
  rescue
    e ->
      Logger.warning("GoogleChat: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Like `send_message/2`, in the background (the caller doesn't wait for Google)."
  def send_async(text) do
    if configured?(), do: Task.start(fn -> send_message(text) end)
    :ok
  end

  @doc "The server's name, to tell several AskDrive servers apart in one space."
  def host do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> "?"
    end
  end

  defp error_detail(%{"error" => %{"message" => message}}), do: message
  defp error_detail(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp error_detail(body), do: inspect(body) |> String.slice(0, 200)
end
