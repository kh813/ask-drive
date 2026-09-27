defmodule AskDrive.Generate.QATest do
  use ExUnit.Case, async: true
  alias AskDrive.Generate.QA

  test "parse_qa_json extracts JSON array from markdown code fences" do
    response = """
    以下の通り想定質問を作成しました。

    ```json
    [
      {
        "question": "リモートワークの手当はいくらですか？",
        "answer": "月額5,000円が在宅勤務手当として支給されます。"
      },
      {
        "question": "申請はどこから行いますか？",
        "answer": "社内ポータルの申請フォームから行います。"
      }
    ]
    ```

    以上です。
    """

    assert {:ok, list} = QA.parse_qa_json(response)
    assert length(list) == 2
    assert List.first(list)["question"] == "リモートワークの手当はいくらですか？"
  end

  test "parse_qa_json parses raw JSON array" do
    response = ~s([{"question": "Q1", "answer": "A1"}])
    assert {:ok, list} = QA.parse_qa_json(response)
    assert length(list) == 1
  end
end
