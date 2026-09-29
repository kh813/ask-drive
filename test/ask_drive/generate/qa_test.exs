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

  describe "parse_qa_json tolerates the shapes models actually return" do
    test "a single object instead of an array" do
      assert {:ok, [%{"question" => "Q"}]} =
               QA.parse_qa_json(~s({"question": "Q", "answer": "A"}))
    end

    test "an object wrapping the array" do
      assert {:ok, [%{"question" => "Q1"}, %{"question" => "Q2"}]} =
               QA.parse_qa_json(
                 ~s({"qa_pairs": [{"question": "Q1", "answer": "A1"}, {"question": "Q2", "answer": "A2"}]})
               )
    end

    test "items missing a field, holding a number, empty, or not objects are dropped" do
      response = """
      [
        {"question": "Q1", "answer": "A1"},
        {"question": "Q2"},
        {"question": "Q3", "answer": 3},
        {"question": " ", "answer": "A4"},
        "just a string",
        {"question": "Q5", "answer": "A5"}
      ]
      """

      assert {:ok, items} = QA.parse_qa_json(response)
      assert Enum.map(items, & &1["question"]) == ["Q1", "Q5"]
    end

    test "nothing usable parses to an empty list (the caller retries once)" do
      assert {:ok, []} = QA.parse_qa_json(~s({"note": "no questions"}))
      assert {:ok, []} = QA.parse_qa_json("[1, 2, 3]")
    end
  end
end
