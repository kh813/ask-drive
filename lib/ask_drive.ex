defmodule AskDrive do
  @moduledoc """
  AskDrive keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  @doc "The running version (mix.exs `version`, kept equal to the release tag)."
  def version, do: Application.spec(:ask_drive, :vsn) |> to_string()
end
