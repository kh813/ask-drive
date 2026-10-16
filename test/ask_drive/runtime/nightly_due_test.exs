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

  test "a run starting at 06:43 gets until 08:00 (deadline separate from the start window)" do
    setting = AskDrive.Settings.get_setting!()
    assert setting.batch_end_hour == 7
    assert setting.batch_deadline_hour == 8

    assert AskDrive.Batch.Scheduler.calculate_deadline(setting, ~N[2026-09-29 06:43:00]) ==
             Clock.local_to_utc(~N[2026-09-29 08:00:00])

    assert Mode.nightly_due?(~N[2026-09-29 06:43:00])
    refute Mode.nightly_due?(~N[2026-09-29 07:10:00])
  end

  test "a desk with its automatic run switched off is never due (F-344)" do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.get_setting!(), %{
        auto_batch_enabled: false
      })

    refute Mode.nightly_due?(~N[2026-09-29 00:30:00])
    assert AskDrive.Batch.Scheduler.auto_status(~N[2026-09-29 00:30:00]).state == :off
  end

  test "a new desk starts with its automatic run switched off; existing ones keep it on" do
    assert AskDrive.Settings.get_setting!().auto_batch_enabled
    legal = AskDrive.AppsHelper.create_app!("legal-due", "Legal")

    AskDrive.Apps.with_app(legal, fn ->
      refute AskDrive.Settings.get_setting!().auto_batch_enabled
      refute Mode.nightly_due?(~N[2026-09-29 00:30:00])
    end)
  end
end
