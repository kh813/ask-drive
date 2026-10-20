defmodule AskDrive.PdfEfficiencyTest do
  @moduledoc """
  PDFs are rated by their text per page, not by text against file size (spec F-1410): a
  manual whose screenshots make the file large is not "Needs improvement"; a scan is.
  """
  use AskDrive.DataCase
  alias AskDrive.{Documents, Metrics}
  alias AskDrive.Documents.{Chunk, Document}

  defp pdf!(attrs, chunks) do
    doc =
      %Document{}
      |> Document.changeset(
        Map.merge(
          %{
            drive_file_id: "pdf-#{System.unique_integer([:positive])}",
            name: "manual.pdf",
            mime_type: "application/pdf",
            status: "indexed"
          },
          attrs
        )
      )
      |> Repo.insert!()

    chunks
    |> Enum.with_index()
    |> Enum.each(fn {{content, page}, i} ->
      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: i,
        content: content,
        page: page,
        content_hash: "h#{i}",
        token_estimate: div(String.length(content), 2)
      })
      |> Repo.insert!()
    end)

    doc
  end

  @step String.duplicate("経費精算システムにログインし、申請メニューから新規申請を選びます。", 4)

  test "a manual full of screenshots (a large file, little text per KB) is Fair, not Needs improvement" do
    doc =
      pdf!(%{size_bytes: 8_000_000, page_count: 3, textless_pages: 0}, [
        {@step <> "以下の画像の赤枠部分のボタンをクリックします。", 1},
        {@step, 2},
        {@step, 3}
      ])

    eff = Metrics.calculate_doc_efficiency(doc)
    # the old rule: under 10% text and under 10 tokens per KB
    assert eff.effective_text_ratio < 10.0 and eff.tokens_per_kb < 10.0
    assert eff.score_level == :fair
    assert eff.advice =~ "スクリーンショット"
  end

  test "a scan (almost no text on its pages) still needs improvement" do
    doc = pdf!(%{size_bytes: 3_000_000, page_count: 10, textless_pages: 9}, [{"社外秘", 1}])
    eff = Metrics.calculate_doc_efficiency(doc)
    assert eff.score_level == :poor
  end

  test "pages with no text are counted in the advice" do
    doc =
      pdf!(%{size_bytes: 2_000_000, page_count: 4, textless_pages: 1}, [
        {@step, 1},
        {@step, 2},
        {@step, 4}
      ])

    eff = Metrics.calculate_doc_efficiency(doc)
    assert eff.score_level == :fair
    assert eff.advice =~ "4 ページ中 1 ページ"
  end

  test "without a recorded page count, the chunks' pages are used" do
    doc = pdf!(%{size_bytes: 5_000_000}, [{@step, 1}, {@step, 2}])
    assert Metrics.calculate_doc_efficiency(doc).pages == 2
    assert Metrics.calculate_doc_efficiency(doc).score_level == :fair
  end

  test "page stats come from the form feeds of the extracted text" do
    assert Documents.page_stats("一枚目の本文です。とても長い説明が続きます。\f\n\f二枚目の本文です。これも十分な長さがあります。") ==
             %{page_count: 3, textless_pages: 1}

    assert Documents.page_stats("no pages") == %{page_count: nil, textless_pages: nil}
  end

  test "references to images are recognized" do
    for text <- ["下図のとおり設定します", "赤枠のボタンを押す", "See the screenshot", "図1 の画面", "Click the red box"] do
      assert Metrics.refers_to_images?([%{content: text}]), text
    end

    refute Metrics.refers_to_images?([%{content: "申請書を提出します"}])
  end
end
