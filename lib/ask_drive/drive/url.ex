defmodule AskDrive.Drive.Url do
  @moduledoc """
  Parser for Google Drive and Google Docs / Sheets / Slides URLs and IDs.
  """

  @doc """
  Parses a Google Drive URL or raw ID and returns `{:ok, %{id: id, type: type}}` or `{:error, reason}`.

  ## Examples

      iex> AskDrive.Drive.Url.parse("https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoP")
      {:ok, %{id: "1aBcDeFgHiJkLmNoP", type: :folder}}

      iex> AskDrive.Drive.Url.parse("https://docs.google.com/document/d/1XyZ_123/edit")
      {:ok, %{id: "1XyZ_123", type: :document}}

      iex> AskDrive.Drive.Url.parse("1aBcDeFgHiJkLmNoP")
      {:ok, %{id: "1aBcDeFgHiJkLmNoP", type: :raw_id}}
  """
  def parse(nil), do: {:error, :empty_url}
  def parse(""), do: {:error, :empty_url}

  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      # Folder URL: /folders/<ID>
      match =
          Regex.run(
            ~r/drive\.google\.com\/drive\/(?:u\/\d+\/)?folders\/([a-zA-Z0-9_-]+)/,
            trimmed
          ) ->
        [_, id] = match
        {:ok, %{id: id, type: :folder}}

      # Docs URL: /document/d/<ID>
      match = Regex.run(~r/docs\.google\.com\/document\/d\/([a-zA-Z0-9_-]+)/, trimmed) ->
        [_, id] = match
        {:ok, %{id: id, type: :document}}

      # Sheets URL: /spreadsheets/d/<ID>
      match = Regex.run(~r/docs\.google\.com\/spreadsheets\/d\/([a-zA-Z0-9_-]+)/, trimmed) ->
        [_, id] = match
        {:ok, %{id: id, type: :spreadsheet}}

      # Slides URL: /presentation/d/<ID>
      match = Regex.run(~r/docs\.google\.com\/presentation\/d\/([a-zA-Z0-9_-]+)/, trimmed) ->
        [_, id] = match
        {:ok, %{id: id, type: :presentation}}

      # Generic Drive File URL: /file/d/<ID>
      match = Regex.run(~r/drive\.google\.com\/file\/d\/([a-zA-Z0-9_-]+)/, trimmed) ->
        [_, id] = match
        {:ok, %{id: id, type: :file}}

      # Raw ID (alphanumeric, dashes, underscores, length >= 10)
      Regex.match?(~r/^[a-zA-Z0-9_-]{10,}$/, trimmed) ->
        {:ok, %{id: trimmed, type: :raw_id}}

      true ->
        {:error, :invalid_drive_url}
    end
  end
end
