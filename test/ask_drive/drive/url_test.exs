defmodule AskDrive.Drive.UrlTest do
  use ExUnit.Case, async: true
  alias AskDrive.Drive.Url

  test "parses folder URLs" do
    assert {:ok, %{id: "1aBcDeFgHiJkLmNoP", type: :folder}} =
             Url.parse("https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoP")

    assert {:ok, %{id: "1aBcDeFgHiJkLmNoP", type: :folder}} =
             Url.parse("https://drive.google.com/drive/u/0/folders/1aBcDeFgHiJkLmNoP")
  end

  test "parses docs, sheets, slides, and generic file URLs" do
    assert {:ok, %{id: "doc_1234567890", type: :document}} =
             Url.parse("https://docs.google.com/document/d/doc_1234567890/edit?usp=sharing")

    assert {:ok, %{id: "sheet_1234567890", type: :spreadsheet}} =
             Url.parse("https://docs.google.com/spreadsheets/d/sheet_1234567890/edit#gid=0")

    assert {:ok, %{id: "slide_1234567890", type: :presentation}} =
             Url.parse("https://docs.google.com/presentation/d/slide_1234567890/edit")

    assert {:ok, %{id: "file_1234567890", type: :file}} =
             Url.parse("https://drive.google.com/file/d/file_1234567890/view")
  end

  test "parses raw folder or file IDs" do
    assert {:ok, %{id: "1aBcDeFgHiJkLmNoP_xyz", type: :raw_id}} =
             Url.parse("1aBcDeFgHiJkLmNoP_xyz")
  end

  test "handles invalid or empty URLs" do
    assert {:error, :empty_url} = Url.parse("")
    assert {:error, :empty_url} = Url.parse(nil)
    assert {:error, :invalid_drive_url} = Url.parse("https://example.com/invalid")
  end
end
