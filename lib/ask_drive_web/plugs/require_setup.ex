defmodule AskDriveWeb.Plugs.RequireSetup do
  @moduledoc """
  Sends every browser request to `/setup` until the first-access setup is done (spec 6.12).
  """
  @behaviour Plug
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{request_path: "/setup" <> _} = conn, _opts), do: conn

  def call(conn, _opts) do
    if AskDrive.Setup.required?(),
      do: conn |> redirect(to: "/setup") |> halt(),
      else: conn
  end
end
