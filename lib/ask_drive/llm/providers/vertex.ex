defmodule AskDrive.LLM.Providers.Vertex do
  @moduledoc """
  Google Agent Platform (formerly Vertex AI) with an API key (spec F-835).

  Agent Platform serves the Gemini models with the Gemini API's request and response
  (`generateContent`, `streamGenerateContent?alt=sse`, `countTokens`, the same
  `x-goog-api-key` header); only the endpoint differs, and it ends the same way —
  `.../publishers/google/models/MODEL:generateContent` — so generation is the Gemini adapter's,
  given this endpoint as its base:

    * no project: the global endpoint, `https://aiplatform.googleapis.com/v1/publishers/google`
      (what an express mode or standard API key is documented with);
    * a project: `https://LOCATION-aiplatform.googleapis.com/v1/projects/PROJECT/locations/LOCATION/publishers/google`
      (`aiplatform.googleapis.com` for the location `global`).

  Generation only: embeddings stay with another provider, and there is no model list for an
  API key (the settings screen suggests the Gemini manual's models instead).
  """
  @behaviour AskDrive.LLM.Provider

  use Gettext, backend: AskDriveWeb.Gettext

  alias AskDrive.LLM.HTTP
  alias AskDrive.LLM.Providers.Gemini

  @global_base_url "https://aiplatform.googleapis.com/v1/publishers/google"

  @impl true
  def local?, do: false

  @impl true
  def supports_embedding?, do: false

  @doc "The endpoint for `project` (optional) and `location` (default `global`)."
  def base_url(project, location) do
    location = if location in [nil, ""], do: "global", else: location

    cond do
      project in [nil, ""] ->
        @global_base_url

      location == "global" ->
        "https://aiplatform.googleapis.com/v1/projects/#{project}/locations/global/publishers/google"

      true ->
        "https://#{location}-aiplatform.googleapis.com/v1/projects/#{project}/locations/#{location}/publishers/google"
    end
  end

  def default_base_url, do: @global_base_url

  @impl true
  def generate(model, prompt, opts \\ []), do: Gemini.generate(model, prompt, endpoint(opts))

  def generate_stream(model, prompt, opts, on_delta),
    do: Gemini.generate_stream(model, prompt, endpoint(opts), on_delta)

  @impl true
  def embed(_model, _inputs, _opts \\ []),
    do: {:error, {:unsupported, gettext("Agent Platform is used for text generation only.")}}

  @impl true
  def list_models(_opts \\ []),
    do: {:error, {:unsupported, gettext("Agent Platform has no model list for an API key.")}}

  @doc """
  Reaches the endpoint with the key by counting the tokens of a word for `opts[:model]`
  (free; nothing is generated). Without a model, only that a key is set can be said.
  """
  @impl true
  def health(opts \\ []) do
    opts = endpoint(opts)

    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        url = "#{opts[:base_url]}/models/#{model}:countTokens"
        body = %{contents: [%{role: "user", parts: [%{text: "ping"}]}]}

        case HTTP.post_json(url, body, headers(opts), 15_000) do
          {:ok, %{"totalTokens" => _}} ->
            {:ok, "#{model} reachable"}

          {:ok, body} ->
            {:error, {:invalid_response, "totalTokens missing: #{inspect(Map.keys(body))}"}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:ok, "API key set"}
    end
  end

  defp endpoint(opts) do
    Keyword.update(opts, :base_url, @global_base_url, fn
      url when is_binary(url) and url != "" -> url
      _ -> @global_base_url
    end)
  end

  defp headers(opts), do: [{"x-goog-api-key", Keyword.get(opts, :api_key) || ""}]
end
