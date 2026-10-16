defmodule AskDriveWeb.PageController do
  use AskDriveWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
