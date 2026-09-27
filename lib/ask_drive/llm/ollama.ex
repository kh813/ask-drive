defmodule AskDrive.LLM.Ollama do
  @moduledoc """
  Client for interacting with local Ollama inference server.
  Supports vector embedding (`/api/embed`), text generation (`/api/generate`), and model unloading.
  """
  require Logger

  @default_embed_timeout 30_000
  @default_generate_timeout 180_000

  @doc """
  Generates vector embeddings for a list of input texts using `/api/embed`.
  """
  def embed(model, inputs, opts \\ []) when is_list(inputs) do
    ollama_host = get_ollama_host()
    timeout = Keyword.get(opts, :timeout, @default_embed_timeout)
    expected_dim = Keyword.get(opts, :expected_dim, 1024)

    payload = %{
      model: model,
      input: inputs
    }

    url = "#{ollama_host}/api/embed"

    case Req.post(url, json: payload, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"embeddings" => embeddings}}} ->
        # Validate dimensions
        invalid =
          Enum.find(embeddings, fn vec ->
            length(vec) != expected_dim
          end)

        if invalid do
          actual_dim = length(invalid)

          Logger.error(
            "Embedding dimension mismatch: expected #{expected_dim}, got #{actual_dim}"
          )

          {:error, {:dimension_mismatch, expected: expected_dim, got: actual_dim}}
        else
          {:ok, embeddings}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama embed error (HTTP #{status}): #{inspect(body)}")
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("Ollama embed network failure: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Generates text completion using Ollama `/api/generate`.
  """
  def generate(model, prompt, opts \\ []) when is_binary(prompt) do
    ollama_host = get_ollama_host()
    timeout = Keyword.get(opts, :timeout, @default_generate_timeout)
    num_ctx = Keyword.get(opts, :num_ctx, 4096)
    system_prompt = Keyword.get(opts, :system, nil)

    payload =
      %{
        model: model,
        prompt: prompt,
        stream: false,
        options: %{
          num_ctx: num_ctx
        }
      }
      |> then(fn p ->
        if system_prompt, do: Map.put(p, :system, system_prompt), else: p
      end)

    url = "#{ollama_host}/api/generate"

    case Req.post(url, json: payload, receive_timeout: timeout) do
      {:ok, %{status: 200, body: %{"response" => response}}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama generate error (HTTP #{status}): #{inspect(body)}")
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        Logger.error("Ollama generate failure: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Unloads a model from memory immediately by setting keep_alive to 0.
  """
  def unload_model(model) when is_binary(model) do
    ollama_host = get_ollama_host()
    url = "#{ollama_host}/api/generate"

    case Req.post(url, json: %{model: model, keep_alive: 0}, receive_timeout: 5000) do
      {:ok, %{status: 200}} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Lists models currently loaded in Ollama memory (`/api/ps`).
  """
  def list_loaded_models do
    ollama_host = get_ollama_host()
    url = "#{ollama_host}/api/ps"

    case Req.get(url, receive_timeout: 3000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, models}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_ollama_host do
    Application.get_env(:ask_drive, :ollama_host) ||
      System.get_env("OLLAMA_HOST") ||
      "http://localhost:11434"
  end
end
