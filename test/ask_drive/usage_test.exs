defmodule AskDrive.UsageTest do
  @moduledoc "Who uses the desks and what is asked often (F-1415, F-1416)."
  use AskDrive.DataCase, async: false

  import AskDrive.AppsHelper

  alias AskDrive.{Apps, Metrics, Usage}
  alias AskDrive.QA.QuestionLog
  alias AskDrive.Usage.QuestionUsage

  defp log!(question, attrs \\ %{}) do
    %QuestionLog{}
    |> QuestionLog.changeset(
      Map.merge(
        %{question: question, tier_reached: 2, asked_at: DateTime.utc_now(:second)},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp asked!(user_id, tokens, attrs \\ %{}) do
    %QuestionUsage{}
    |> QuestionUsage.changeset(
      Map.merge(%{user_id: user_id, tokens: tokens, asked_at: DateTime.utc_now(:second)}, attrs)
    )
    |> Repo.insert!()
  end

  defp api_call(tokens),
    do:
      Metrics.record(%{
        provider: "ollama",
        model: "m",
        purpose: "chat_summary",
        total_tokens: tokens
      })

  test "a question is recorded for its asker with the tokens it used, never its text" do
    user = AskDriveWeb.ConnCase.user_fixture()

    result =
      Usage.track_question(user, false, fn ->
        api_call(120)
        %{tier: 2, question_log_id: 7, question: "有給の申請方法"}
      end)

    usage = Repo.get!(QuestionUsage, result.usage_id)
    assert %{user_id: uid, tier: 2, question_log_id: 7, tokens: 120, follow_up: false} = usage
    assert uid == user.id
    refute usage |> Map.from_struct() |> Map.values() |> Enum.member?("有給の申請方法")

    # the AI summary's tokens are added to the same question
    assert {:ok, :done} =
             Usage.track_tokens(result.usage_id, fn ->
               api_call(30)
               {:ok, :done}
             end)

    assert Repo.get!(QuestionUsage, result.usage_id).tokens == 150

    # outside a question, API calls aren't counted for anyone
    api_call(999)
    assert Repo.get!(QuestionUsage, result.usage_id).tokens == 150
  end

  test "the guest (sign-in off) is recorded as user 0" do
    result = Usage.track_question(nil, true, fn -> %{tier: 3, question_log_id: nil} end)
    assert %{user_id: 0, follow_up: true} = Repo.get!(QuestionUsage, result.usage_id)
  end

  test "a desk's report: people by questions or tokens, with their solved rate" do
    alice = AskDriveWeb.ConnCase.user_fixture(name: "Alice")
    bob = AskDriveWeb.ConnCase.user_fixture(name: "Bob")

    solved = log!("a", %{tier_reached: 1})
    unsolved = log!("b")
    asked!(alice.id, 10, %{question_log_id: solved.id})
    asked!(alice.id, 10, %{question_log_id: unsolved.id})
    asked!(bob.id, 500)
    asked!(0, 5)
    # older than the period
    asked!(bob.id, 1, %{asked_at: DateTime.add(DateTime.utc_now(:second), -40 * 86_400)})

    report = Usage.desk_report(30)
    assert %{questions: 4, tokens: 525, users: 2} = report

    assert [
             %{user_id: a, name: "Alice", questions: 2, solved_rate: 50},
             %{user_id: b, kind: :user, questions: 1},
             %{user_id: 0, kind: :guest}
           ] = report.people

    assert {a, b} == {alice.id, bob.id}

    assert [%{name: "Bob", tokens: 500} | _] = Usage.desk_report(30, sort: :tokens).people
    assert Usage.desk_report(90).questions == 5
  end

  test "frequent questions: the same wording asked at least twice, follow-ups left out" do
    log!("有給の申請方法？", %{tier_reached: 1})
    log!("有給の申請方法")
    log!("有給の 申請方法？")
    log!("VPN がつながらない")
    log!("VPN がつながらない")
    # asked once: someone's own circumstances never show up
    log!("私の給与が少ない理由")
    log!("有給の申請方法 / 何日前まで？", %{follow_up: true})
    log!("有給の申請方法 / 何日前まで？", %{follow_up: true})

    assert [
             %{question: _, count: 3, solved: 1},
             %{question: "VPN がつながらない", count: 2, solved: 0}
           ] = Usage.frequent_questions(30)
  end

  test "the platform's report adds each person up over every desk" do
    user = AskDriveWeb.ConnCase.user_fixture(name: "Carol")
    asked!(user.id, 100)
    hr = create_app!("hr", "人事部窓口")
    Apps.with_app(hr, fn -> asked!(user.id, 40) && asked!(user.id, 60) end)

    report = Usage.platform_report(30)
    assert %{questions: 3, tokens: 200, users: 1, desks: 2} = report
    assert [%{name: "Carol", questions: 3, desks: desks}] = report.people
    assert [%{app: %{slug: "hr"}, questions: 2, tokens: 100}, %{questions: 1}] = desks
  end

  test "rows older than 90 days are deleted" do
    old = asked!(1, 1, %{asked_at: DateTime.add(DateTime.utc_now(:second), -91 * 86_400)})
    recent = asked!(1, 1)
    assert Usage.prune() == 1
    refute Repo.get(QuestionUsage, old.id)
    assert Repo.get(QuestionUsage, recent.id)
  end
end
