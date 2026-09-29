defmodule AskDrive.Metrics do
  @moduledoc """
  Context for logging and analyzing LLM and API usage metrics (tokens, payload size, latency, errors)
  without logging confidential user prompts or search terms (spec 14.5, N-606).
  """
  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.Metrics.ApiUsageLog
  alias AskDrive.Repo

  @doc """
  Records an API usage log entry safely. Does not raise or fail callers if logging encounters an issue.
  """
  def record(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    # Calculate total_tokens if not provided
    prompt_tokens = Map.get(attrs, :prompt_tokens) || Map.get(attrs, "prompt_tokens") || 0

    completion_tokens =
      Map.get(attrs, :completion_tokens) || Map.get(attrs, "completion_tokens") || 0

    total_tokens =
      Map.get(attrs, :total_tokens) || Map.get(attrs, "total_tokens") ||
        prompt_tokens + completion_tokens

    attrs =
      attrs
      |> Map.put(:prompt_tokens, prompt_tokens)
      |> Map.put(:completion_tokens, completion_tokens)
      |> Map.put(:total_tokens, total_tokens)

    try do
      %ApiUsageLog{}
      |> ApiUsageLog.changeset(attrs)
      |> Repo.insert()

      :ok
    rescue
      e ->
        Logger.warning("Metrics.record failed: #{inspect(e)}")
        :ok
    end
  end

  @doc """
  Returns high-level summary statistics of API usage for the current Repo.
  """
  def get_summary(days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    base_query = from l in ApiUsageLog, where: l.inserted_at >= ^since

    total_requests = Repo.aggregate(base_query, :count, :id) || 0

    error_requests =
      Repo.one(from l in base_query, where: l.status == "error", select: count(l.id)) || 0

    totals =
      Repo.one(
        from l in base_query,
          select: %{
            prompt_tokens: coalesce(sum(l.prompt_tokens), 0),
            completion_tokens: coalesce(sum(l.completion_tokens), 0),
            total_tokens: coalesce(sum(l.total_tokens), 0),
            total_bytes: coalesce(sum(l.request_bytes), 0),
            avg_latency: coalesce(avg(l.latency_ms), 0.0)
          }
      ) ||
        %{
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
          total_bytes: 0,
          avg_latency: 0.0
        }

    provider_breakdown =
      Repo.all(
        from l in base_query,
          group_by: [l.provider, l.model],
          select: %{
            provider: l.provider,
            model: l.model,
            requests: count(l.id),
            total_tokens: coalesce(sum(l.total_tokens), 0),
            errors: count(fragment("CASE WHEN ? = 'error' THEN 1 END", l.status))
          },
          order_by: [desc: count(l.id)]
      )

    purpose_breakdown =
      Repo.all(
        from l in base_query,
          group_by: l.purpose,
          select: %{
            purpose: l.purpose,
            requests: count(l.id),
            total_tokens: coalesce(sum(l.total_tokens), 0)
          },
          order_by: [desc: count(l.id)]
      )

    %{
      days: days,
      total_requests: total_requests,
      error_requests: error_requests,
      success_rate:
        if(total_requests > 0,
          do: Float.round((total_requests - error_requests) / total_requests * 100, 1),
          else: 100.0
        ),
      prompt_tokens: totals.prompt_tokens,
      completion_tokens: totals.completion_tokens,
      total_tokens: totals.total_tokens,
      total_bytes: totals.total_bytes,
      avg_latency_ms: round(totals.avg_latency),
      provider_breakdown: provider_breakdown,
      purpose_breakdown: purpose_breakdown
    }
  end

  @doc """
  Lists recent API error logs (for debugging failures).
  """
  def list_recent_errors(limit \\ 20) do
    Repo.all(
      from l in ApiUsageLog,
        where: l.status == "error",
        order_by: [desc: l.inserted_at],
        limit: ^limit
    )
  end

  @doc """
  Lists recent API usage logs.
  """
  def list_recent_logs(limit \\ 50) do
    Repo.all(
      from l in ApiUsageLog,
        order_by: [desc: l.inserted_at],
        limit: ^limit
    )
  end
end
