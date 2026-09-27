defmodule AskDrive.Settings do
  @moduledoc """
  Context for managing application settings (singleton).
  """
  import Ecto.Query, warn: false
  alias AskDrive.Repo
  alias AskDrive.Settings.Setting

  @doc """
  Gets the singleton setting record. If none exists, creates and returns the default setting.
  """
  def get_setting! do
    case Repo.one(from s in Setting, limit: 1) do
      nil ->
        {:ok, setting} =
          %Setting{}
          |> Setting.changeset(%{
            batch_start_hour: 21,
            batch_end_hour: 7,
            batch_model: "qwen3:4b",
            embed_model: "bge-m3",
            batch_num_ctx: 4096,
            similarity_threshold: 0.65,
            serve_stale_qa: false,
            daytime_llm_enabled: false
          })
          |> Repo.insert()

        setting

      setting ->
        setting
    end
  end

  @doc """
  Gets the singleton setting record (nullable).
  """
  def get_setting do
    Repo.one(from s in Setting, limit: 1)
  end

  @doc """
  Updates the singleton setting.
  """
  def update_setting(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking setting changes.
  """
  def change_setting(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, attrs)
  end
end
