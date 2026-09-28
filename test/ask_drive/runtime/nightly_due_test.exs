defmodule AskDrive.Runtime.NightlyDueTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.BatchRun
  alias AskDrive.Clock
  alias AskDrive.Runtime.Mode

  defp run!(local_start, attrs) do
    %BatchRun{}
    |> BatchRun.changeset(
      Map.merge(%{started_at: Clock.local_to_utc(local_start), status: "completed"}, attrs)
    )
    |> Repo.insert!()
  end

  test "outside the night window nothing is due" do
    refute Mode.nightly_due?(~N[2026-09-28 15:00:00])
  end

  test "a manual batch aborted by a restart (as on 2026-09-28 22:11) leaves the night due" do
    run!(~N[2026-09-28 22:11:22], %{status: "aborted", kind: "full"})
    assert Mode.nightly_due?(~N[2026-09-28 23:00:00])
  end

  test "an ingest-only run doesn't count as the night's batch" do
    run!(~N[2026-09-28 22:30:00], %{kind: "ingest_only"})
    assert Mode.nightly_due?(~N[2026-09-28 23:00:00])
  end

  test "a completed full batch in the window means it's done for the night" do
    run!(~N[2026-09-28 22:30:00], %{kind: "full"})
    refute Mode.nightly_due?(~N[2026-09-28 23:00:00])
    refute Mode.nightly_due?(~N[2026-09-29 03:00:00])
    # ...but the next night is due again
    assert Mode.nightly_due?(~N[2026-09-29 21:05:00])
  end

  test "a full batch before the window opened doesn't count" do
    run!(~N[2026-09-28 20:30:00], %{kind: "full"})
    assert Mode.nightly_due?(~N[2026-09-28 21:01:00])
  end
end
