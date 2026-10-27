defmodule AskDriveWeb.SummaryMarkdownTest do
  @moduledoc "The AI summary's Markdown is shown as such, from escaped text (F-437)."
  use ExUnit.Case, async: true

  alias AskDriveWeb.SummaryMarkdown

  defp html(text, cite \\ fn whole, _n -> whole end),
    do: text |> SummaryMarkdown.to_html(cite) |> LazyHTML.from_fragment()

  defp texts(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1)

  test "a reasoned answer: nested bullets with bold labels, and a paragraph before them" do
    doc =
      html("""
      いいえ、この共有ドライブ名は命名規則に沿っていません。

      * **空白文字の使用**
          * **規則:** 空白文字は利用できません [2]。
          * **当てはめ:** 「SEng_Electronic Stamp Keepers」に空白が含まれます。
      * **形式の不一致**
          * **規則:** `[社名]_[部門]-[目的]` の形式 [1]。
      """)

    assert texts(doc, "p") == ["いいえ、この共有ドライブ名は命名規則に沿っていません。"]
    nested = texts(doc, "ul ul li strong")
    assert nested == ["規則:", "当てはめ:", "規則:"]
    # the two topics at the top, each with its points nested under it
    assert texts(doc, "ul > li > strong") -- nested == ["空白文字の使用", "形式の不一致"]
    assert Enum.count(LazyHTML.query(doc, "ul > li > ul")) == 2
    # the name's underscore is not italics; code is kept as written
    assert texts(doc, "em") == []
    assert texts(doc, "code") == ["[社名]_[部門]-[目的]"]
  end

  test "numbered lists, headings, rules and line breaks" do
    doc =
      html("""
      ## 手順
      1. 上長の承認を取る
      2. IT サポートに依頼する
      ---
      問い合わせ先:
      IT サポート
      """)

    assert texts(doc, "p.font-semibold") == ["手順"]
    assert texts(doc, "ol > li") == ["上長の承認を取る", "IT サポートに依頼する"]
    assert Enum.count(LazyHTML.query(doc, "hr")) == 1
    assert Enum.count(LazyHTML.query(doc, "p br")) == 1
    assert texts(doc, "em") == []
  end

  test "*italics* and citations through the given function" do
    doc = html("これは *重要* です [1]。", fn _whole, n -> ~s(<a id="c#{n}">[#{n}]</a>) end)
    assert texts(doc, "em") == ["重要"]
    assert texts(doc, "a#c1") == ["[1]"]
  end

  test "the model's own markup is escaped, never run" do
    out = SummaryMarkdown.to_html("<script>alert(1)</script> **<b>x</b>**")
    refute out =~ "<script>"
    refute out =~ "<b>"
    assert out =~ "&lt;script&gt;"
    assert out =~ ~s(<strong class="font-semibold">&lt;b&gt;x&lt;/b&gt;</strong>)
  end

  test "text still streaming: an unclosed ** stays as written" do
    assert SummaryMarkdown.to_html("* **規則") =~ "**規則"
  end
end
