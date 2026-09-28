defmodule AskDriveWeb.Plugs.ResetApp do
  @moduledoc """
  Starts every HTTP request in the platform context (spec 6.11).

  An app page's first (static) render selects that app's database in the request process.
  With keep-alive, the same process then serves the connection's next request — which would
  otherwise still be pointed at that app's database (a login, say, reading the app's
  settings instead of the platform's). The context is also reset right before the response
  is sent.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    reset()
    # and again once the response is rendered, so the process never idles pointed at an app
    Plug.Conn.register_before_send(conn, fn conn ->
      reset()
      conn
    end)
  end

  defp reset do
    AskDrive.Repo.put_dynamic_repo(AskDrive.Repo)
    Process.delete({AskDrive.Apps, :current})
  end
end
