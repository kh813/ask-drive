defmodule AskDrive.Metrics.ApiUsageLog do
  @moduledoc """
  Schema for tracking API usage, token counts, request bytes, latency, and errors
  across LLM calls (spec 14.5).
  Strictly avoids storing user query texts or document contents to respect privacy (N-606).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_usage_logs" do
    field :provider, :string
    field :model, :string
    field :purpose, :string
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :total_tokens, :integer, default: 0
    field :request_bytes, :integer, default: 0
    field :latency_ms, :integer, default: 0
    field :status, :string, default: "ok"
    field :error_message, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields [
    :provider,
    :model,
    :purpose,
    :prompt_tokens,
    :completion_tokens,
    :total_tokens,
    :request_bytes,
    :latency_ms,
    :status,
    :error_message,
    :inserted_at
  ]

  def changeset(log, attrs) do
    log
    |> cast(attrs, @fields)
    |> validate_required([:provider, :model, :purpose, :status])
    |> validate_inclusion(:status, ["ok", "error"])
  end
end
