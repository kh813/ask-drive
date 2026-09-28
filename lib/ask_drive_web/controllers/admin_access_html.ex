defmodule AskDriveWeb.AdminAccessHTML do
  @moduledoc """
  Elevation prompt rendered by `AskDriveWeb.AdminAccessController`.
  """
  use AskDriveWeb, :html

  embed_templates "admin_access_html/*"
end
