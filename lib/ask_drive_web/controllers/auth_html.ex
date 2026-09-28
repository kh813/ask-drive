defmodule AskDriveWeb.AuthHTML do
  @moduledoc """
  Sign-in page rendered by `AskDriveWeb.AuthController`.
  """
  use AskDriveWeb, :html

  embed_templates "auth_html/*"
end
