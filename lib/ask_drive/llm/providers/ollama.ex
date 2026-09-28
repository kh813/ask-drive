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

    timeout = Keyword.get(opts, :timeout, @embed_timeout)

    case HTTP.post_json(url, payload, [], timeout, retry: Keyword.get(opts, :retry, true)) do
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
        options: ollama_options(opts)
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

  @doc """
  Streams a completion from `/api/generate`, calling `on_delta.(text)` for each piece as it
  arrives, and returns `{:ok, full_text}`. If `on_delta` returns `:halt`, generation stops
  there (the request is closed) and the text so far is returned. Used for the chat summary (spec 6.4.4), where a
  local model takes tens of seconds and showing text as it is written matters.

  `think: false` keeps reasoning models (qwen3) from spending the budget on a hidden
  chain of thought before the answer.
  """
  def generate_stream(model, prompt, opts, on_delta) when is_function(on_delta, 1) do
    think = Keyword.get(opts, :think, false)
    on_thinking = Keyword.get(opts, :on_thinking, fn _ -> :ok end)

    payload =
      %{
        model: model,
        prompt: prompt,
        stream: true,
        options: ollama_options(opts)
      }
      |> maybe_put(:think, think)
      |> maybe_put(:system, Keyword.get(opts, :system))
      |> put_keep_alive(opts)

    collect = fn {:data, data}, {req, resp} ->
      buffer = Req.Response.get_private(resp, :buffer, "") <> data

      if resp.status == 200 do
        {lines, rest} = split_lines(buffer)

        {text, halt?} =
          Enum.reduce(lines, {"", false}, fn
            _line, {text, true} ->
              {text, true}

            line, {text, false} ->
              case Jason.decode(line) do
                # With think: true, Ollama returns a reasoning model's thinking in its own
                # field, so the answer ("response") needs no tag parsing.
                {:ok, %{"thinking" => thought}} when is_binary(thought) and thought != "" ->
                  {text, on_thinking.(thought) == :halt}

                {:ok, %{"response" => piece}} when is_binary(piece) and piece != "" ->
                  # on_delta may answer :halt to stop generation early (e.g. length cap)
                  {text <> piece, on_delta.(piece) == :halt}

                _ ->
                  {text, false}
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

    case Req.post(base_url(opts) <> "/api/generate",
           json: payload,
           into: collect,
           receive_timeout: Keyword.get(opts, :timeout, @generate_timeout),
           retry: false
         ) do
      {:ok, %{status: 200} = resp} ->
        {:ok, Req.Response.get_private(resp, :text, "")}

      {:ok, %{status: 400} = resp} when think == true ->
        # Models whose template has no thinking support reject think: true; answer anyway
        body = Req.Response.get_private(resp, :buffer, "")

        if String.contains?(body, "think"),
          do: generate_stream(model, prompt, Keyword.put(opts, :think, nil), on_delta),
          else: {:error, HTTP.classify(400, decode_body(body))}

      {:ok, %{status: status} = resp} ->
        body = Req.Response.get_private(resp, :buffer, "")
        {:error, HTTP.classify(status, decode_body(body))}

      {:error, %{__struct__: Req.TransportError, reason: :timeout}} ->
        {:error, {:timeout, "receive timeout"}}

      {:error, reason} ->
        {:error, {:network, reason}}
    end
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> body
    end
  end

  # num_predict caps the answer length: without it a max_tokens given by the caller (e.g. the
  # chat summary's) was simply ignored by Ollama and answers ran on.
  defp ollama_options(opts) do
    %{num_ctx: Keyword.get(opts, :num_ctx, 4096)}
    |> maybe_put(:num_predict, Keyword.get(opts, :max_tokens))
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.reject(complete, &(&1 == "")), rest}
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
