defmodule AskDrive.Updates.ServerTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.Batch.{BatchRun, Scheduler}
  alias AskDrive.Updates
  alias AskDrive.Updates.Server

  @envs [
    :update_build_command,
    :update_service_check,
    :update_restart_fun,
    :update_poll_ms,
    :update_halt_ms,
    :update_resume_ms
  ]

  setup do
    test = self()
    File.rm_rf!(Path.dirname(Server.marker_path()))

    Application.put_env(
      :ask_drive,
      :update_build_command,
      {"/bin/sh", ["-c", "echo building; echo built"]}
    )

    Application.put_env(:ask_drive, :update_service_check, fn -> true end)
    Application.put_env(:ask_drive, :update_restart_fun, fn -> send(test, :restarted) end)
    Application.put_env(:ask_drive, :update_poll_ms, 20)
    Application.put_env(:ask_drive, :update_halt_ms, 0)
    Application.put_env(:ask_drive, :update_resume_ms, 600_000)

    restart_server()
    Phoenix.PubSub.subscribe(AskDrive.PubSub, Server.topic())

    on_exit(fn ->
      Enum.each(@envs, &Application.delete_env(:ask_drive, &1))
      # a marker left by a restart must not be picked up once this test's database is gone
      File.rm_rf!(Path.dirname(Server.marker_path()))
      restart_server()
    end)
  end

  # a fresh server (it is a singleton of the application)
  defp restart_server do
    :ok = Supervisor.terminate_child(AskDrive.Supervisor, Server)
    {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, Server)
  end

  defp running_run!(attrs \\ %{}) do
    %BatchRun{}
    |> BatchRun.changeset(Map.merge(%{started_at: DateTime.utc_now(), status: "running"}, attrs))
    |> Repo.insert!()
  end

  defp wait_for_phase(phase) do
    assert_receive {:update_status, %{phase: ^phase} = status}, 5_000
    status
  end

  test "builds while the server runs, then restarts, telling every page (F-1502, F-1505)" do
    Phoenix.PubSub.subscribe(AskDrive.PubSub, "system")
    assert :ok = Updates.start(by: "admin@example.com", to: "9.9.9")
    assert {:error, :busy} = Updates.start(by: "someone else")
    assert Updates.busy?()

    wait_for_phase(:restarting)
    assert_receive {:system_updating, %{to: "9.9.9"}}
    assert_receive :restarted

    status = Updates.status()
    assert "building" in status.log

    marker = Server.marker_path() |> File.read!() |> Jason.decode!()
    assert %{"from" => _, "to" => "9.9.9", "by" => "admin@example.com"} = marker
  end

  test "a failed build changes nothing: no restart" do
    Application.put_env(
      :ask_drive,
      :update_build_command,
      {"/bin/sh", ["-c", "echo oops; exit 3"]}
    )

    :ok = Updates.start(by: "admin")

    status = wait_for_phase(:failed)
    assert status.message =~ "終了コード 3"
    refute_received :restarted
    refute Updates.busy?()
    refute File.exists?(Server.marker_path())
  end

  test "the build can be cancelled" do
    Application.put_env(:ask_drive, :update_build_command, {"/bin/sh", ["-c", "sleep 30"]})
    :ok = Updates.start(by: "admin")
    assert :ok = Updates.cancel()
    assert Updates.status().phase == :failed
    refute Updates.busy?()
  end

  test "without a service manager it stops after the build: restart by hand" do
    Application.put_env(:ask_drive, :update_service_check, fn -> false end)
    run = running_run!()
    :ok = Updates.start(by: "admin")

    status = wait_for_phase(:built)
    assert status.message =~ "./app.sh restart"
    # the batch was left alone
    assert Repo.get!(BatchRun, run.id).stop_requested_at == nil
    refute_received :restarted
  end

  test "a running batch is paused at its next boundary; nothing starts meanwhile; restarts once it has (F-1503)" do
    run = running_run!(%{trigger: "manual", kind: "ingest_only"})
    :ok = Updates.start(by: "admin")

    # (the phase is entered first, so nothing starts in between; then the batch is paused)
    assert_receive {:update_status,
                    %{phase: :waiting_batch, message: "ビルドが完了しました。バッチが区切りで" <> _}},
                   5_000

    run = Repo.get!(BatchRun, run.id)
    assert run.stop_reason == "update" and run.stop_requested_at
    assert Updates.restart_pending?()
    assert {:error, :updating} = Scheduler.run_batch()
    refute_received :restarted

    # the batch reaches its boundary
    run |> Ecto.Changeset.change(status: "paused") |> Repo.update!()
    assert_receive :restarted, 2_000

    marker = Server.marker_path() |> File.read!() |> Jason.decode!()
    assert %{"manual" => [%{"kind" => "ingest_only"}], "night" => nil} = marker["resume"]
  end

  test "waiting for the batch to finish doesn't pause it or hold other batches back" do
    run = running_run!()
    :ok = Updates.start(by: "admin", wait: :batch_end)

    wait_for_phase(:waiting_batch)
    assert Repo.get!(BatchRun, run.id).stop_requested_at == nil
    refute Updates.restart_pending?()
    assert Updates.busy?()

    run |> Ecto.Changeset.change(status: "completed") |> Repo.update!()
    assert_receive :restarted, 2_000
  end

  test "after the restart: the result is recorded" do
    File.mkdir_p!(Path.dirname(Server.marker_path()))

    File.write!(
      Server.marker_path(),
      Jason.encode!(%{"from" => "0.0.1", "to" => AskDrive.version(), "by" => "admin@example.com"})
    )

    restart_server()
    _ = :sys.get_state(Server)

    refute File.exists?(Server.marker_path())

    assert AskDrive.Settings.platform_setting!().update_last_result =~
             "v#{AskDrive.version()} にアップデートしました"

    assert Server.boot_result(%{"from" => "1.0.0", "to" => "1.1.0"}, "1.0.0") =~ "のままで起動しました"
  end

  test "a paused waiting run is recorded as paused, and a run stopped for an update ends as paused" do
    {:ok, waiting} = Scheduler.run_batch(trigger: "auto", stage: :ingest, night: true)
    assert waiting.status == "waiting"
    Scheduler.pause_for_update()
    assert %{status: "paused", stop_reason: "update"} = Repo.get!(BatchRun, waiting.id)

    {:ok, waiting} = Scheduler.run_batch(trigger: "auto", stage: :ingest, night: true)

    waiting
    |> Ecto.Changeset.change(
      stop_requested_at: DateTime.utc_now() |> DateTime.truncate(:second),
      stop_reason: "update"
    )
    |> Repo.update!()

    assert {:ok, %BatchRun{status: "paused"}} = Scheduler.resume_batch(waiting.id)
  end
end
