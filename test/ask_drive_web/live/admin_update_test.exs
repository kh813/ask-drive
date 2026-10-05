defmodule AskDriveWeb.AdminUpdateTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Updates.Server

  setup %{conn: conn} do
    test = self()
    File.rm_rf!(Path.dirname(Server.marker_path()))
    Application.put_env(:ask_drive, :update_build_command, {"/bin/sh", ["-c", "echo building"]})
    Application.put_env(:ask_drive, :update_service_check, fn -> true end)
    Application.put_env(:ask_drive, :update_restart_fun, fn -> send(test, :restarted) end)
    Application.put_env(:ask_drive, :update_halt_ms, 0)

    on_exit(fn ->
      for key <- [
            :update_build_command,
            :update_service_check,
            :update_restart_fun,
            :update_halt_ms
          ],
          do: Application.delete_env(:ask_drive, key)

      File.rm_rf!(Path.dirname(Server.marker_path()))
      :ok = Supervisor.terminate_child(AskDrive.Supervisor, Server)
      {:ok, _} = Supervisor.restart_child(AskDrive.Supervisor, Server)
    end)

    admin = user_fixture(admin_eligible: true)
    %{conn: log_in_admin(conn, admin), admin: admin}
  end

  test "the platform admin's update tab: versions, nightly settings, starting an update (F-1501)",
       %{
         conn: conn,
         admin: admin
       } do
    {:ok, _} =
      AskDrive.Settings.update_setting(AskDrive.Settings.platform_setting!(), %{})

    AskDrive.Updates.save_platform(%{update_latest_version: "99.0.0"})

    {:ok, view, _html} = live(conn, "/admin?tab=update")
    assert has_element?(view, "#update-panel")
    assert has_element?(view, "#update-latest", "v99.0.0")
    assert has_element?(view, "#update-available-badge", "v99.0.0")

    view
    |> form("#update-settings-form", %{
      "setting" => %{"update_check_enabled" => "false", "update_auto_apply" => "true"}
    })
    |> render_submit()

    setting = AskDrive.Settings.platform_setting!()
    refute setting.update_check_enabled
    assert setting.update_auto_apply

    view |> form("#start-update-form", %{"wait" => "boundary"}) |> render_submit()
    assert_receive :restarted, 5_000
    assert has_element?(view, "#update-progress")
    assert AskDrive.Updates.status().by == admin.email
  end

  test "only the platform screen has the update tab, not a desk's", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, "/admin")
    assert has_element?(view, "#tab-update")

    {:ok, view, _html} = live(log_in_app_admin(conn, admin), "/it-support/admin")
    refute has_element?(view, "#tab-update")
    refute has_element?(view, "#update-available-badge")
  end

  test "every open page is told to show 'updating' before the restart (F-1505)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/it-support")

    Phoenix.PubSub.broadcast(
      AskDrive.PubSub,
      "system",
      {:system_updating, %{from: "1.0.0", to: "1.1.0"}}
    )

    assert_push_event(view, "askdrive:updating", %{title: _, message: message})
    assert message =~ "v1.1.0"
  end
end
