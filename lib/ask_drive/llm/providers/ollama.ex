defmodule AskDrive.LLM.Providers.Ollama do
  @moduledoc """
  Local Ollama adapter (spec 8.2).

  Uses `/api/embed` (plural) exclusively — the legacy `/api/embeddings` takes a single
  string and makes batch ingestion an order of magnitude slower.
  """
  @behaviour AskDrive.LLM.Provider

  alias AskDrive.LLM.HTTP

  @default_base_url "http://localhost:11434"
  @embed_timeout 30_000
  @generate_timeout 180_000

  @impl true
  def local?, do: true

  @impl true
  def supports_embedding?, do: true

  @impl true
  def embed(model, inputs, opts \\ []) when is_list(inputs) do
    payload =
      %{model: model, input: inputs}
      |> put_keep_alive(opts)

    url = base_url(opts) <> "/api/embed"

    case HTTP.post_json(url, payload, [], Keyword.get(opts, :timeout, @embed_timeout)) do
      {:ok, %{"embeddings" => embeddings}} when is_list(embeddings) ->
        {:ok, embeddings}

      {:ok, body} ->
        {:error, {:invalid_response, "embeddings missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def generate(model, prompt, opts \\ []) when is_binary(prompt) do
    payload =
      %{
        model: model,
        prompt: prompt,
        stream: false,
        options: %{num_ctx: Keyword.get(opts, :num_ctx, 4096)}
      }
      |> maybe_put(:system, Keyword.get(opts, :system))
      |> put_keep_alive(opts)

    url = base_url(opts) <> "/api/generate"

    case HTTP.post_json(url, payload, [], Keyword.get(opts, :timeout, @generate_timeout)) do
      {:ok, %{"response" => response}} when is_binary(response) ->
        {:ok, response}

      {:ok, body} ->
        {:error, {:invalid_response, "response missing: #{inspect(Map.keys(body))}"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_models(opts \\ []) do
    case HTTP.get_json(base_url(opts) <> "/api/tags", [], 5_000, retry: false) do
      {:ok, %{"models" => models}} when is_list(models) ->
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health(opts \\ []) do
    case HTTP.get_json(base_url(opts) <> "/api/version", [], 3_000, retry: false) do
      {:ok, %{"version" => version}} -> {:ok, "v#{version}"}
      {:ok, _} -> {:ok, "connected"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Unloads a model from memory immediately (`keep_alive: 0`). Best effort — a failure here
  only costs memory headroom, so it never propagates an error to the phase transition.
  """
  def unload_model(model, opts \\ []) when is_binary(model) do
    Req.post(base_url(opts) <> "/api/generate",
      json: %{model: model, keep_alive: 0},
      receive_timeout: 5_000,
      retry: false
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Lists models currently resident in Ollama memory (`/api/ps`).
  """
  def list_loaded_models(opts \\ []) do
    case HTTP.get_json(base_url(opts) <> "/api/ps", [], 3_000, retry: false) do
      {:ok, %{"models" => models}} -> {:ok, models}
      {:ok, _} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Default endpoint used when neither settings nor `OLLAMA_HOST` provide one.
  """
  def default_base_url do
    Application.get_env(:ask_drive, :ollama_host) ||
      System.get_env("OLLAMA_HOST") ||
      @default_base_url
  end

  defp base_url(opts) do
    opts
    |> Keyword.get(:base_url)
    |> case do
      url when is_binary(url) and url != "" -> url
      _ -> default_base_url()
    end
    |> String.trim_trailing("/")
  end

  defp put_keep_alive(payload, opts) do
    maybe_put(payload, :keep_alive, Keyword.get(opts, :keep_alive))
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)
end
