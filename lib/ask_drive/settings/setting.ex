defmodule AskDrive.Settings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :drive_folder_id, :string
    field :drive_folder_name, :string
    field :batch_start_hour, :integer, default: 21
    field :batch_end_hour, :integer, default: 7
    field :batch_model, :string, default: "qwen3:4b"
    field :embed_model, :string, default: "bge-m3"
    field :batch_num_ctx, :integer, default: 4096
    field :similarity_threshold, :float, default: 0.65
    field :serve_stale_qa, :boolean, default: false
    field :daytime_llm_enabled, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [
      :drive_folder_id,
      :drive_folder_name,
      :batch_start_hour,
      :batch_end_hour,
      :batch_model,
      :embed_model,
      :batch_num_ctx,
      :similarity_threshold,
      :serve_stale_qa,
      :daytime_llm_enabled
    ])
    |> validate_required([
      :batch_start_hour,
      :batch_end_hour,
      :batch_model,
      :embed_model,
      :batch_num_ctx,
      :similarity_threshold
    ])
    |> validate_number(:batch_start_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:batch_end_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:similarity_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:batch_num_ctx, greater_than: 512)
  end
end
