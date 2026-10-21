defmodule AskDrive.UserSolvedTest do
  @moduledoc "「解決した」 and follow-ups as what the asker says of an answer (F-433)."
  use AskDrive.DataCase, async: false

  alias AskDrive.{Metrics, QA}
  alias AskDrive.QA.QuestionLog

  defp question!(tier) do
    Repo.insert!(%QuestionLog{
      question: "q#{tier}",
      tier_reached: tier,
      asked_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  defp ids(logs), do: logs |> Enum.map(& &1.id) |> Enum.sort()

  test "a QA answer followed up on is unresolved; 「解決した」 takes an excerpt answer off the admin's list" do
    qa_answered = question!(1)
    excerpt = question!(2)

    assert ids(QA.list_unresolved_questions()) == [excerpt.id]

    :ok = QA.mark_followed_up(qa_answered.id)
    assert ids(QA.list_unresolved_questions()) == Enum.sort([qa_answered.id, excerpt.id])

    :ok = QA.mark_solved(excerpt.id, true)
    assert ids(QA.list_unresolved_questions()) == [qa_answered.id]
    # still in for the nightly batch: a QA pair answers it at once next time
    assert excerpt.id in ids(Repo.all(QA.unresolved_query()))

    # pressed again: taken back
    :ok = QA.mark_solved(excerpt.id, false)
    assert excerpt.id in ids(QA.list_unresolved_questions())
  end

  test "a follow-up takes back a 「解決した」" do
    log = question!(2)
    :ok = QA.mark_solved(log.id, true)
    :ok = QA.mark_followed_up(log.id)

    log = Repo.get!(QuestionLog, log.id)
    assert log.followed_up_at
    refute log.user_solved_at
  end

  test "the desk's solved count follows what the askers said" do
    followed = question!(1)
    _qa = question!(0)
    solved_excerpt = question!(2)
    _excerpt = question!(2)

    :ok = QA.mark_followed_up(followed.id)
    :ok = QA.mark_solved(solved_excerpt.id, true)

    summary = Metrics.desk_summary()
    assert summary.questions == 4
    assert summary.solved == 2
    assert summary.unsolved == 2
    assert summary.user_solved == 1
    assert summary.followed_up == 1
  end
end
