defmodule AskDrive.Runtime.NightlyDueTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.BatchRun
  alias AskDrive.Clock
  alias AskDrive.Runtime.Mode

  defp run!(local_start, attrs) do
    %BatchRun{}
    |> BatchRun.changeset(
      Map.merge(
        %{started_at: Clock.local_to_utc(local_start), status: "completed", trigger: "auto"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "the window is 00:00-07:00 by default" do
    refute Mode.nightly_due?(~N[2026-09-28 23:30:00])
    assert Mode.nightly_due?(~N[2026-09-29 00:01:00])
    assert Mode.nightly_due?(~N[2026-09-29 06:59:00])
    refute Mode.nightly_due?(~N[2026-09-29 07:00:00])
  end

  test "manual runs in the evening (as on 2026-09-28 22:09) don't cancel the night's run" do
    run!(~N[2026-09-28 22:09:00], %{trigger: "manual", kind: "full"})
    run!(~N[2026-09-29 00:10:00], %{trigger: "manual", kind: "full"})
    assert Mode.nightly_due?(~N[2026-09-29 00:30:00])
  end

  test "an automatic run aborted by a restart leaves the night due" do
    run!(~N[2026-09-29 00:00:30], %{status: "aborted"})
    assert Mode.nightly_due?(~N[2026-09-29 00:30:00])
  end

  test "an ingest-only run doesn't count as the night's batch" do
    run!(~N[2026-09-29 00:05:00], %{kind: "ingest_only"})
    assert Mode.nightly_due?(~N[2026-09-29 00:30:00])
  end

  test "a completed automatic run means it's done for the night; the next night is due" do
    run!(~N[2026-09-29 00:00:30], %{kind: "full"})
    refute Mode.nightly_due?(~N[2026-09-29 03:00:00])
    assert Mode.nightly_due?(~N[2026-09-30 00:01:00])
  end
end
