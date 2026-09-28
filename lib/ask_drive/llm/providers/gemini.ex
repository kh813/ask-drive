defmodule AskDrive.LLM.Providers.Gemini do
  @moduledoc """
  Google Gemini API adapter (spec 8.5).

  The key travels in the `x-goog-api-key` header rather than a query string, so it does not
  end up in proxy or access logs (spec 9.6 N-606).
  """
  @behaviour AskDrive.LLM.Provider

  alias AskDrive.LLM.HTTP

  @default_base_url "https://generativelanguage.googleapis.com/v1beta"
  @embed_timeout 60_000
  @generate_timeout 120_000

  @impl true
  def local?, do: false

  @impl true
  def supports_embedding?, do: true

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(prompt) do
    url = "#{base_url(opts)}/models/#{model}:generateContent"

    case HTTP.post_json(
           url,
           payload(prompt, opts),
           headers(opts),
           Keyword.get(opts, :timeout, @generate_timeout)
         ) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} when is_list(parts) ->
        case answer_text(parts) do
          "" -> {:error, {:invalid_response, "no text part in response"}}
          text -> {:ok, text}
        end

      {:ok, %{"promptFeedback" => %{"blockReason" => reason}}} ->
        {:error, {:invalid_response, "blocked by safety filter: #{reason}"}}

      {:ok, body} ->
        {:error, {:invalid_response, "candidates missing: #{inspect(Map.keys(body))}"}}

      {:error, {:invalid_response, message}} = error ->
        if thinking_rejected?(message, opts),
          do: generate(model, prompt, Keyword.put(opts, :think, nil)),
          else: error

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams a completion via `streamGenerateContent` (server-sent events), calling
  `on_delta.(text)` per piece; `:halt` from `on_delta` stops the stream. Returns
  `{:ok, full_text}`. Used for the chat summary, so the answer appears as it is written.
  """
  def generate_stream(model, prompt, opts, on_delta) when is_function(on_delta, 1) do
    url = "#{base_url(opts)}/models/#{model}:streamGenerateContent?alt=sse"

    collect = fn {:data, data}, {req, resp} ->
      buffer = Req.Response.get_private(resp, :buffer, "") <> data

      if resp.status == 200 do
        {events, rest} = split_events(buffer)

        {text, halt?} =
          Enum.reduce(events, {"", false}, fn
            _event, {text, true} ->
              {text, true}

            event, {text, false} ->
              case event_text(event) do
                "" -> {text, false}
                piece -> {text <> piece, on_delta.(piece) == :halt}
              end
          end)

        acc = Req.Response.get_private(resp, :text, "") <> text

        resp =
          resp |> Req.Response.put_private(:buffer, rest) |> Req.Response.put_private(:text, acc)

        if halt?, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
      else
        {:cont, {req, Req.Response.put_private(resp, :buffer, buffer)}}
      end
    end

    case Req.post(url,
           json: payload(prompt, opts),
           headers: headers(opts),
           into: collect,
           receive_timeout: Keyword.get(opts, :timeout, @generate_timeout),
           retry: false
         ) do
      {:ok, %{status: 200} = resp} ->
        {:ok, Req.Response.get_private(resp, :text, "")}

      {:ok, %{status: status} = resp} ->
        body = decode(Req.Response.get_private(resp, :buffer, ""))
        {_kind, message} = error = HTTP.classify(status, body)

        if status == 400 and thinking_rejected?(message, opts),
          do: generate_stream(model, prompt, Keyword.put(opts, :think, nil), on_delta),
          else: {:error, error}

      {:error, %{__struct__: Req.TransportError, reason: :timeout}} ->
        {:error, {:timeout, "receive timeout"}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  # think: false turns Gemini 2.5+'s default reasoning off (thinkingBudget 0) — its thinking
  # tokens count against maxOutputTokens, so a short chat-summary cap would otherwise be
  # spent before any answer. Models that can't switch it off reject the request; the callers
  # then retry without it.
  defp payload(prompt, opts) do
    thinking =
      case Keyword.get(opts, :think) do
        false -> %{thinkingBudget: 0}
        _ -> nil
      end

    generation_config =
      %{}
      |> maybe_put(:maxOutputTokens, Keyword.get(opts, :max_tokens))
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:thinkingConfig, thinking)

    %{contents: [%{role: "user", parts: [%{text: prompt}]}]}
    |> maybe_put(:systemInstruction, system_instruction(opts))
    |> maybe_put(:generationConfig, presence(generation_config))
  end

  defp thinking_rejected?(message, opts) do
    Keyword.get(opts, :think) == false and is_binary(message) and
      String.contains?(String.downcase(message), "think")
  end

  # Parts flagged `thought: true` are the model's reasoning, not the answer.
  defp answer_text(parts) do
    parts
    |> Enum.reject(&(&1["thought"] == true))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  defp split_events(buffer) do
    parts = String.split(buffer, ~r/\r?\n\r?\n/)
    {complete, [rest]} = Enum.split(parts, -1)
    {complete, rest}
  end

  defp event_text(event) do
    event
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map_join("", fn "data:" <> json ->
      case Jason.decode(String.trim(json)) do
        {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} -> answer_text(parts)
        _ -> ""
      end
    end)
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> body
    end
  end

  @impl true
  def embed(model, inputs, opts \\ []) when is_list(inputs) do
    dim = Keyword.get(opts, :expected_dim)

    requests =
      Enum.map(inputs, fn text ->
        %{model: "models/#{model}", content: %{parts: [%{text: text}]}}
        |> maybe_put(:outputDimensionality, dim)
      end)

    url = "#{base_url(opts)}/models/#{model}:batchEmbedContents"

    case HTTP.post_json(
           url,
           %{requests: requests},
           headers(opts),
           Keyword.get(opts, :timeout, @embed_timeout)
         ) do
      {:ok, %{"embeddings" => embeddings}} when is_list(embeddings) ->
        vectors = Enum.map(embeddings, &Map.get(&1, "values"))

        if Enum.all?(vectors, &is_list/1) do
          {:ok, vectors}
        else
          {:error, {:invalid_response, "embedding entry missing values"}}
        end

      {:ok, body} ->
        {:error, {:invalid_response, "embeddings missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(opts \\ []) do
    case HTTP.get_json(base_url(opts) <> "/models", headers(opts), 10_000, retry: false) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok,
         Enum.map(models, &(&1 |> Map.get("name", "") |> String.replace_prefix("models/", "")))}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health(opts \\ []) do
    case list_models(opts) do
      {:ok, models} -> {:ok, "#{length(models)} models available"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Default endpoint used when settings provide none.
  """
  def default_base_url, do: System.get_env("GEMINI_BASE_URL") || @default_base_url

  defp base_url(opts) do
    opts
    |> Keyword.get(:base_url)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> default_base_url()
    end
    |> String.trim_trailing("/")
  end

  defp headers(opts), do: [{"x-goog-api-key", Keyword.get(opts, :api_key) || ""}]

  defp system_instruction(opts) do
    case Keyword.get(opts, :system) do
      system when is_binary(system) and system != "" -> %{parts: [%{text: system}]}
      _ -> nil
    end
  end

  defp presence(map) when map_size(map) == 0, do: nil
  defp presence(map), do: map

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
