defmodule AskDrive.Ingest.ExtractorTest do
  use ExUnit.Case, async: true
  alias AskDrive.Ingest.Extractor

  test "extracts plain text and computes SHA-256 hash" do
    text = "これはテスト文書です。\n第二段落の内容です。"
    assert {:ok, result} = Extractor.extract_binary(text, "text/plain")
    assert result.text == text
    assert result.content_hash == Extractor.content_hash(text)
  end

  test "extracts markdown and json text" do
    md = "# タイトル\n\n- 項目1\n- 項目2"
    assert {:ok, result} = Extractor.extract_binary(md, "text/markdown")
    assert result.text == md

    json = ~s({"name": "山田", "role": "エンジニア"})
    assert {:ok, json_res} = Extractor.extract_binary(json, "application/json")
    assert json_res.text == json
  end

  test "routes text/html through pandoc instead of passing raw markup through" do
    html = "<html><body><h1>タイトル</h1><p>本文です。</p></body></html>"

    case Extractor.extract_binary(html, "text/html") do
      {:ok, result} ->
        # Cleanly extracted: tags gone, text content kept.
        refute result.text =~ "<"
        assert result.text =~ "タイトル"
        assert result.text =~ "本文です"

      {:skipped, reason} ->
        # No pandoc in this environment — still proves html no longer falls into the
        # raw-passthrough text branch (which would have returned {:ok, ...} with tags intact).
        assert reason =~ "pandoc"
    end
  end

  test "returns skipped for unsupported MIME types" do
    assert {:skipped, reason} = Extractor.extract_binary(<<0, 1, 2, 3>>, "video/mp4")
    assert reason =~ "Unsupported MIME type"
  end

  test "content_hash produces lowercase 64-char hex string" do
    hash = Extractor.content_hash("hello world")
    assert byte_size(hash) == 64
    assert hash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
  end
end
