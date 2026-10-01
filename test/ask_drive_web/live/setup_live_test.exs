defmodule AskDriveWeb.SetupLiveTest do
  use AskDriveWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias AskDrive.Setup

  setup do
    dir = Path.join(System.tmp_dir!(), "askdrive_setup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:ask_drive, :setup_dir, dir)
    Application.put_env(:ask_drive, :setup_check, true)
    System.put_env("ASK_DRIVE_DISABLE_AUTH", "true")
    Setup.reset_cache()
    if :ets.whereis(Setup) != :undefined, do: :ets.delete_all_objects(Setup)

    on_exit(fn ->
      Application.put_env(:ask_drive, :setup_check, false)
      Application.delete_env(:ask_drive, :setup_dir)
      System.delete_env("ASK_DRIVE_DISABLE_AUTH")
      Setup.reset_cache()
      File.rm_rf(dir)
    end)

    :ok
  end

  test "every page leads to /setup until setup is done", %{conn: conn} do
    assert redirected_to(get(conn, "/")) == "/setup"
    assert redirected_to(get(conn, "/it-support")) == "/setup"
    assert redirected_to(get(conn, "/admin")) == "/setup"
  end

  test "the setup form reports errors, then completes and goes to the apps screen", %{conn: conn} do
    code = Setup.ensure_code()
    {:ok, view, html} = live(conn, "/setup")
    assert html =~ "初回セットアップ"
    assert html =~ "./app.sh status"

    html =
      view
      |> form("#setup-form", %{
        "code" => "BAD",
        "domain" => "",
        "app_name" => "IT"
      })
      |> render_submit()

    assert html =~ "セットアップコードが正しくありません"
    assert html =~ "ドメインを入力してください"

    {:error, {:redirect, %{to: "/admin?tab=apps"}}} =
      view
      |> form("#setup-form", %{
        "code" => code,
        "domain" => "example.com",
        "app_name" => "IT-Support",
        "admin_emails" => "owner@example.com"
      })
      |> render_submit()

    # and /setup is no longer offered
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/setup")
  end
end
