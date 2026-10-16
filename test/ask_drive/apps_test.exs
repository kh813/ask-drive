defmodule AskDrive.AppsTest do
  use AskDrive.DataCase, async: false

  alias AskDrive.{Answering, Apps, Settings}
  alias AskDrive.Apps.App
  alias AskDrive.Documents.{Chunk, Document}
  import AskDrive.AppsHelper

  test "without any app row the primary app is virtual and uses the platform database" do
    assert [%App{slug: "it-support", primary: true} = primary] = Apps.list()
    assert Apps.repo_for(primary) == AskDrive.Repo
  end

  test "slugs are validated and reserved paths refused" do
    assert {:error, cs} = Apps.create(%{slug: "admin", name: "x"})
    assert cs.errors[:slug]
    assert {:error, cs} = Apps.create(%{slug: "Bad Slug!", name: "x"})
    assert cs.errors[:slug]
  end

  test "a new app gets its own database and settings: Drive and API keys empty, the rest copied" do
    {:ok, _} =
      Settings.update_setting(Settings.get_setting!(), %{
        drive_folder_id: "primary-folder",
        gemini_api_key: "primary-key",
        tier1_threshold: 0.93
      })

    hr = create_app!("hr", "HR")
    assert File.exists?(hr.db_path)

    hr_setting = Apps.with_app(hr, &Settings.get_setting!/0)
    assert hr_setting.drive_folder_id == nil
    assert hr_setting.gemini_api_key == nil
    assert hr_setting.tier1_threshold == 0.93

    # the primary app's settings are untouched
    assert Settings.get_setting!().drive_folder_id == "primary-folder"
  end

  test "documents and answers stay inside their app" do
    hr = create_app!("hr", "HR")

    Apps.with_app(hr, fn ->
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          drive_file_id: "hr1",
          name: "就業規則",
          mime_type: "text/plain",
          status: "indexed"
        })
        |> Repo.insert()

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        position: 0,
        content_hash: "h",
        content: "有給休暇は入社6か月後に10日付与する。"
      })
      |> Repo.insert!()
    end)

    # HR finds it; the primary (IT-Support) app doesn't even see the document
    hr_answer = Apps.with_app(hr, fn -> Answering.ask("有給休暇は何日？") end)
    assert hr_answer.tier == 2
    assert [%{document: %{name: "就業規則"}} | _] = hr_answer.chunks

    it_answer = Answering.ask("有給休暇は何日？")
    assert it_answer.tier == 3
    refute Repo.exists?(from d in Document, where: d.drive_file_id == "hr1")
  end

  test "bind/1 carries the app into another process" do
    hr = create_app!("hr", "HR")

    task_app =
      Apps.with_app(hr, fn ->
        Task.async(Apps.bind(fn -> Apps.current() end)) |> Task.await()
      end)

    assert task_app.slug == "hr"
    assert Task.async(Apps.bind(fn -> Apps.current() end)) |> Task.await() == nil
  end

  test "users stay platform-wide even from an app's process" do
    hr = create_app!("hr", "HR")
    {:ok, user} = AskDrive.Accounts.upsert_user_from_login(%{email: "a@example.com"})

    assert Apps.with_app(hr, fn -> AskDrive.Accounts.get_user(user.id) end).email ==
             "a@example.com"
  end

  test "deleting an app keeps its database file (renamed); the primary can't be deleted" do
    hr = create_app!("hr", "HR")
    assert {:ok, _} = Apps.delete(hr)
    refute File.exists?(hr.db_path)
    assert [_renamed] = Path.wildcard(hr.db_path <> ".deleted-*")
    assert Apps.delete(Apps.primary()) == {:error, :primary}
  end
end
