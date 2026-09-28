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
    generation_config =
      %{}
      |> maybe_put(:maxOutputTokens, Keyword.get(opts, :max_tokens))
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))

    payload =
      %{contents: [%{role: "user", parts: [%{text: prompt}]}]}
      |> maybe_put(:systemInstruction, system_instruction(opts))
      |> maybe_put(:generationConfig, presence(generation_config))

    url = "#{base_url(opts)}/models/#{model}:generateContent"

    case HTTP.post_json(
           url,
           payload,
           headers(opts),
           Keyword.get(opts, :timeout, @generate_timeout)
         ) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} when is_list(parts) ->
        text = Enum.map_join(parts, "", &Map.get(&1, "text", ""))

        if text == "" do
          {:error, {:invalid_response, "no text part in response"}}
        else
          {:ok, text}
        end

      {:ok, %{"promptFeedback" => %{"blockReason" => reason}}} ->
        {:error, {:invalid_response, "blocked by safety filter: #{reason}"}}

      {:ok, body} ->
        {:error, {:invalid_response, "candidates missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
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
