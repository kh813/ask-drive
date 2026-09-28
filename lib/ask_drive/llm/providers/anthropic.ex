defmodule AskDrive.LLM.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API adapter (spec 8.4).

  Claude offers no embedding endpoint, so `supports_embedding?/0` is false and
  `AskDrive.LLM` refuses to route embeddings here.
  """
  @behaviour AskDrive.LLM.Provider

  alias AskDrive.LLM.HTTP

  @default_base_url "https://api.anthropic.com"
  @api_version "2023-06-01"
  @generate_timeout 120_000
  # The Messages API requires max_tokens, so a caller that omits it still needs a value.
  @default_max_tokens 4_096

  @impl true
  def local?, do: false

  @impl true
  def supports_embedding?, do: false

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(prompt) do
    payload =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens) || @default_max_tokens,
        messages: [%{role: "user", content: prompt}]
      }
      |> maybe_put(:system, Keyword.get(opts, :system))
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))

    url = base_url(opts) <> "/v1/messages"

    case HTTP.post_json(
           url,
           payload,
           headers(opts),
           Keyword.get(opts, :timeout, @generate_timeout)
         ) do
      {:ok, %{"content" => blocks}} when is_list(blocks) ->
        text =
          blocks
          |> Enum.filter(&(Map.get(&1, "type") == "text"))
          |> Enum.map_join("", &Map.get(&1, "text", ""))

        if text == "" do
          {:error, {:invalid_response, "no text block in response"}}
        else
          {:ok, text}
        end

      {:ok, body} ->
        {:error, {:invalid_response, "content missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def embed(_model, _inputs, _opts \\ []) do
    {:error, {:unsupported, "Claude API は埋め込みに対応していません。埋め込みには別のプロバイダを選択してください。"}}
  end

  @impl true
  def list_models(opts \\ []) do
    case HTTP.get_json(base_url(opts) <> "/v1/models", headers(opts), 10_000, retry: false) do
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
  Default endpoint used when settings provide none.
  """
  def default_base_url, do: System.get_env("ANTHROPIC_BASE_URL") || @default_base_url

  defp base_url(opts) do
    opts
    |> Keyword.get(:base_url)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> default_base_url()
    end
    |> String.trim_trailing("/")
  end

  defp headers(opts) do
    [
      {"x-api-key", Keyword.get(opts, :api_key) || ""},
      {"anthropic-version", @api_version}
    ]
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, _key, ""), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
