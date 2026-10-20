defmodule AskDrive.Ingest.FileTypesTest do
  @moduledoc """
  Only documents are indexed (spec F-356): manuals' folders also hold batch files, programs
  and source code, which used to be indexed whenever Drive gave them a `text/` type.
  """
  use ExUnit.Case, async: true
  alias AskDrive.Ingest.FileTypes

  test "documents are indexed" do
    for {name, mime} <- [
          {"手順書", "application/vnd.google-apps.document"},
          {"一覧", "application/vnd.google-apps.spreadsheet"},
          {"説明", "application/vnd.google-apps.presentation"},
          {"manual.pdf", "application/pdf"},
          {"規程.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"},
          {"台帳.XLSX", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
          {"研修.pptx",
           "application/vnd.openxmlformats-officedocument.presentationml.presentation"},
          {"旧規程.doc", "application/msword"},
          {"旧台帳.xls", "application/vnd.ms-excel"},
          {"旧研修.ppt", "application/vnd.ms-powerpoint"},
          {"readme.txt", "text/plain"},
          {"手順.md", "text/markdown"},
          {"一覧.csv", "text/csv"},
          {"help.html", "text/html"},
          {"README", "text/plain"},
          # uploaded with a generic type
          {"manual.pdf", "application/octet-stream"}
        ] do
      assert FileTypes.indexable?(name, mime), "#{name} (#{mime}) should be indexed"
    end
  end

  test "programs, scripts and source code are left out, whatever type Drive gives them" do
    for {name, mime} <- [
          {"setup.exe", "application/x-msdownload"},
          {"backup.bat", "application/x-msdos-program"},
          {"run.bat", "text/plain"},
          {"deploy.sh", "text/x-sh"},
          {"tool.py", "text/x-python"},
          {"main.js", "application/javascript"},
          {"config.json", "application/json"},
          {"settings.yaml", "application/x-yaml"},
          {"data.xml", "application/xml"},
          {"tools.zip", "application/zip"},
          {"photo.png", "image/png"},
          {"Makefile", "application/octet-stream"},
          {"フォーム", "application/vnd.google-apps.form"}
        ] do
      refute FileTypes.indexable?(name, mime), "#{name} (#{mime}) should be left out"
    end
  end

  test "the reason names the extension and can be recognized" do
    reason = FileTypes.excluded_reason("tool.py", "text/x-python")
    assert reason =~ ".py"
    assert FileTypes.excluded_reason?(reason)
    refute FileTypes.excluded_reason?("Missing external CLI tool: pandoc")
    refute FileTypes.excluded_reason?(nil)
  end
end
