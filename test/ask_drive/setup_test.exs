defmodule AskDrive.SetupTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{Apps, Settings, Setup}

  setup do
    dir = Path.join(System.tmp_dir!(), "askdrive_setup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:ask_drive, :setup_dir, dir)
    Application.put_env(:ask_drive, :setup_check, true)
    Setup.reset_cache()
    if :ets.whereis(Setup) != :undefined, do: :ets.delete_all_objects(Setup)

    on_exit(fn ->
      Application.put_env(:ask_drive, :setup_check, false)
      Application.delete_env(:ask_drive, :setup_dir)
      Setup.reset_cache()
      File.rm_rf(dir)
    end)

    :ok
  end

  defp valid_params(code) do
    %{
      "code" => code,
      "domain" => "@Example.COM ",
      "app_name" => "情シス相談窓口",
      "admin_emails" => "Owner@example.com, second@example.com"
    }
  end

  test "a fresh install needs setup; prepare writes a setup code only the owner can read" do
    assert Setup.required?()
    code = Setup.prepare()
    assert code =~ ~r/^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/
    assert File.read!(Setup.code_path()) |> String.trim() == code
    assert Bitwise.band(File.stat!(Setup.code_path()).mode, 0o077) == 0
    # stable across restarts until used
    assert Setup.ensure_code() == code
  end

  test "completing setup sets the domain, first app name and administrators, and burns the code" do
    code = Setup.ensure_code()
    assert :ok = Setup.complete(valid_params(String.downcase(code)))

    setting = Settings.get_setting!()
    assert setting.allowed_domain == "example.com"
    assert setting.setup_completed_at
    assert Apps.primary().name == "情シス相談窓口"
    # the platform administrators, also the default app's administrators (F-1116)
    assert AskDrive.Accounts.list_app_admins(Apps.primary().slug) |> Enum.map(& &1.email) ==
             ["owner@example.com", "second@example.com"]

    assert AskDrive.Accounts.list_eligible_admins() |> Enum.map(& &1.email) ==
             ["owner@example.com", "second@example.com"]

    refute File.exists?(Setup.code_path())

    Setup.reset_cache()
    refute Setup.required?()
  end

  test "each invalid field is reported and nothing is saved" do
    Setup.ensure_code()

    assert {:error, errors} =
             Setup.complete(%{
               "code" => "WRONG",
               "domain" => "not a domain",
               "app_name" => "",
               "admin_emails" => ""
             })

    assert errors.code =~ "正しくありません"
    refute Map.has_key?(errors, :password)
    assert errors.domain =~ "ドメイン名"
    assert errors.app_name
    assert errors.admin_emails =~ "全体管理者"
    refute Settings.get_setting!().setup_completed_at
  end

  test "wrong codes are locked out after 10 attempts" do
    code = Setup.ensure_code()
    for _ <- 1..10, do: assert({:error, :invalid} = Setup.verify_code("NOPE-NOPE-NOPE"))
    assert {:error, :locked} = Setup.verify_code(code)
  end

  test "an installation that already has a platform administrator and a domain is marked complete" do
    {:ok, _} = AskDrive.Accounts.grant_admin("boss@example.com")
    {:ok, _} = Settings.update_setting(Settings.get_setting!(), %{allowed_domain: "example.com"})

    refute Setup.required?()
    assert Settings.get_setting!().setup_completed_at
  end
end
