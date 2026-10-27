defmodule AskDrive.ChatSummaryTidyTest do
  @moduledoc "What the summary's model got wrong is cleaned up (F-435)."
  use ExUnit.Case, async: true

  alias AskDrive.ChatSummary

  test "the 「not covered」 line after an answer is dropped; alone it stays" do
    answer = """
    - 名前に空白が含まれるため、命名規則に沿っていません [2]。

    資料からは確認できませんでした。
    """

    assert ChatSummary.tidy(answer, 3) == "- 名前に空白が含まれるため、命名規則に沿っていません [2]。"
    assert ChatSummary.tidy("資料からは確認できませんでした。", 3) == "資料からは確認できませんでした。"

    assert ChatSummary.tidy("「資料からは確認できませんでした。」\n- 空白は使えません [1]", 3) ==
             "- 空白は使えません [1]"

    assert ChatSummary.tidy("Spaces aren't allowed [1].\nThe documents don't cover this.", 2) ==
             "Spaces aren't allowed [1]."
  end

  test "a sentence that only mentions it within an answer is kept" do
    answer = "空白は使えません [1]。期限については資料からは確認できませんでした。"
    assert ChatSummary.tidy(answer, 3) == answer
  end

  test "citations of excerpts that don't exist are dropped" do
    assert ChatSummary.tidy("範囲に該当しない [4]。形式に合わない [2]。", 3) ==
             "範囲に該当しない。形式に合わない [2]。"

    assert ChatSummary.tidy("両方に書かれています [1, 5]。", 3) == "両方に書かれています [1]。"
    assert ChatSummary.tidy("どれにも [0]。", 3) == "どれにも。"
  end
end
