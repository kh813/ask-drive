defmodule AskDrive.LLM.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions / Embeddings adapter (spec 8.3).

  `AskDrive.LLM.Providers.LMStudio` reuses this module with `flavor: :lmstudio`, because
  LM Studio speaks the same wire protocol. The two differences that matter are the token
  limit parameter name (`max_completion_tokens` vs `max_tokens`) and the `dimensions`
  parameter, which only OpenAI's `text-embedding-3-*` models accept.
  """
  @behaviour AskDrive.LLM.Provider

  alias AskDrive.LLM.HTTP

  @default_base_url "https://api.openai.com/v1"
  @embed_timeout 60_000
  @generate_timeout 120_000

  @impl true
  def local?, do: false

  @impl true
  def supports_embedding?, do: true

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(prompt) do
    messages =
      case Keyword.get(opts, :system) do
        system when is_binary(system) and system != "" ->
          [%{role: "system", content: system}, %{role: "user", content: prompt}]

        _ ->
          [%{role: "user", content: prompt}]
      end

    payload =
      %{model: model, messages: messages}
      |> put_token_limit(opts)
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))

    url = base_url(opts) <> "/chat/completions"

    case HTTP.post_json(
           url,
           payload,
           headers(opts),
           Keyword.get(opts, :timeout, @generate_timeout)
         ) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}}
      when is_binary(content) ->
        {:ok, content}

      {:ok, body} ->
        {:error, {:invalid_response, "choices missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def embed(model, inputs, opts \\ []) when is_list(inputs) do
    payload =
      %{model: model, input: inputs}
      |> maybe_put(:dimensions, embedding_dimensions(model, opts))

    url = base_url(opts) <> "/embeddings"

    case HTTP.post_json(url, payload, headers(opts), Keyword.get(opts, :timeout, @embed_timeout)) do
      {:ok, %{"data" => data}} when is_list(data) ->
        # The API may return results out of order, so sort by the echoed index.
        vectors =
          data
          |> Enum.sort_by(&Map.get(&1, "index", 0))
          |> Enum.map(&Map.get(&1, "embedding"))

        if Enum.all?(vectors, &is_list/1) do
          {:ok, vectors}
        else
          {:error, {:invalid_response, "embedding entry missing a vector"}}
        end

      {:ok, body} ->
        {:error, {:invalid_response, "data missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(opts \\ []) do
    case HTTP.get_json(base_url(opts) <> "/models", headers(opts), 10_000, retry: false) do
      {:ok, %{"data" => data}} when is_list(data) -> {:ok, Enum.map(data, & &1["id"])}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
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
  Default endpoint for the given flavor.
  """
  def default_base_url(:lmstudio) do
    System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234/v1"
  end

  def default_base_url(_openai) do
    System.get_env("OPENAI_BASE_URL") || @default_base_url
  end

  defp base_url(opts) do
    opts
    |> Keyword.get(:base_url)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> default_base_url(Keyword.get(opts, :flavor, :openai))
    end
    |> String.trim_trailing("/")
  end

  defp headers(opts) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
      # LM Studio serves an unauthenticated endpoint.
      _ -> []
    end
  end

  # OpenAI renamed the parameter; LM Studio and other compatible servers only know the old one.
  defp put_token_limit(payload, opts) do
    case Keyword.get(opts, :max_tokens) do
      nil ->
        payload

      limit ->
        case Keyword.get(opts, :flavor, :openai) do
          :lmstudio -> Map.put(payload, :max_tokens, limit)
          _ -> Map.put(payload, :max_completion_tokens, limit)
        end
    end
  end

  # `dimensions` is rejected by every model except OpenAI's text-embedding-3 family.
  defp embedding_dimensions(model, opts) do
    if Keyword.get(opts, :flavor, :openai) == :openai and
         String.starts_with?(model, "text-embedding-3") do
      Keyword.get(opts, :expected_dim)
    end
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
