defmodule AskDrive.LLM do
  @moduledoc """
  Facade over the configured LLM providers (spec 6.8).

  Callers (`Answering`, `Generate.*`, `Batch.*`, `Runtime.Mode`) never name a provider:
  they call `generate/3` and `embed/3`, and this module resolves the adapter, endpoint and
  credentials from `settings`, falling back to environment variables when the singleton has
  not been configured yet.

  Generation and embedding are resolved independently, so the common "embeddings stay on
  local `bge-m3`, generation moves to a cloud API" setup needs no re-indexing.
  """
  require Logger

  alias AskDrive.LLM.HTTP
  alias AskDrive.LLM.Providers.{Anthropic, Gemini, LMStudio, Ollama, OpenAI}
  alias AskDrive.Settings

  @providers %{
    "ollama" => Ollama,
    "lmstudio" => LMStudio,
    "gemini" => Gemini,
    "anthropic" => Anthropic,
    "openai" => OpenAI
  }

  @labels %{
    "ollama" => "Ollama (ローカル)",
    "lmstudio" => "LM Studio (ローカル)",
    "gemini" => "Google Gemini API",
    "anthropic" => "Anthropic Claude API",
    "openai" => "OpenAI API"
  }

  @default_provider "ollama"

  # --- Provider registry ----------------------------------------------------

  @doc "All provider identifiers, in display order."
  def providers,
    do: Map.keys(@providers) |> Enum.sort_by(&Enum.find_index(order(), fn p -> p == &1 end))

  @doc "Provider identifiers usable for text generation."
  def generation_providers, do: order()

  @doc "Provider identifiers usable for embedding. Claude has no embedding endpoint."
  def embedding_providers, do: Enum.filter(order(), &module(&1).supports_embedding?())

  @doc "Human readable name for a provider identifier."
  def label(provider), do: Map.get(@labels, normalize(provider), provider)

  @doc "Adapter module for a provider identifier."
  def module(provider), do: Map.get(@providers, normalize(provider), Ollama)

  @doc "Whether the provider runs inference on this machine."
  def local?(provider), do: module(provider).local?()

  @doc "Whether the provider needs an API key before it can be used."
  def requires_api_key?(provider), do: normalize(provider) in ["gemini", "anthropic", "openai"]

  # --- Configured providers -------------------------------------------------

  @doc "Provider identifier used for text generation."
  def generation_provider(setting \\ nil) do
    setting
    |> resolve_setting()
    |> field(:llm_provider, "ASK_DRIVE_LLM_PROVIDER", @default_provider)
    |> normalize()
  end

  @doc "Provider identifier used for embedding."
  def embedding_provider(setting \\ nil) do
    provider =
      setting
      |> resolve_setting()
      |> field(:embed_provider, "ASK_DRIVE_EMBED_PROVIDER", @default_provider)
      |> normalize()

    # Guard against a stale value that can no longer embed (e.g. anthropic).
    if module(provider).supports_embedding?(), do: provider, else: @default_provider
  end

  @doc "Whether generation currently runs locally. Drives R-106."
  def local_generation?(setting \\ nil), do: local?(generation_provider(setting))

  @doc "Whether embedding currently runs locally. Drives R-107."
  def local_embedding?(setting \\ nil), do: local?(embedding_provider(setting))

  @doc "Embedding dimension the vector tables are built for."
  def embedding_dim(setting \\ nil) do
    case resolve_setting(setting) do
      %{embedding_dim: dim} when is_integer(dim) and dim > 0 -> dim
      _ -> env_integer("ASK_DRIVE_EMBEDDING_DIM", 1024)
    end
  end

  @doc """
  Whether the configured provider has everything it needs to run.
  Returns `:ok` or `{:error, message}`.
  """
  def configured(role, setting \\ nil) when role in [:generation, :embedding] do
    setting = resolve_setting(setting)

    provider =
      if role == :generation, do: generation_provider(setting), else: embedding_provider(setting)

    cond do
      role == :embedding and not module(provider).supports_embedding?() ->
        {:error, "#{label(provider)} は埋め込みに対応していません。"}

      requires_api_key?(provider) and api_key(provider, setting) in [nil, ""] ->
        {:error, "#{label(provider)} の API キーが未設定です。"}

      true ->
        :ok
    end
  end

  # --- Inference ------------------------------------------------------------

  @doc """
  Generates text with the configured generation provider.
  """
  def generate(model, prompt, opts \\ []) when is_binary(prompt) do
    setting = resolve_setting(Keyword.get(opts, :setting))
    provider = Keyword.get(opts, :provider) || generation_provider(setting)

    with :ok <- check_api_key(provider, setting) do
      module(provider).generate(model, prompt, generation_opts(provider, setting, opts))
    end
  end

  @doc """
  Like `generate/3`, but calls `on_delta.(text)` as the answer is written, for providers
  that can stream (Ollama). Others generate the whole answer and deliver it in one call, so
  callers need not care which provider is configured.
  """
  def generate_stream(model, prompt, opts, on_delta) when is_function(on_delta, 1) do
    setting = resolve_setting(Keyword.get(opts, :setting))
    provider = Keyword.get(opts, :provider) || generation_provider(setting)
    mod = module(provider)
    gen_opts = generation_opts(provider, setting, opts)

    with :ok <- check_api_key(provider, setting) do
      Code.ensure_loaded(mod)

      if function_exported?(mod, :generate_stream, 4) do
        mod.generate_stream(model, prompt, gen_opts, on_delta)
      else
        with {:ok, text} <- mod.generate(model, prompt, gen_opts) do
          on_delta.(text)
          {:ok, text}
        end
      end
    end
  end

  @doc """
  Embeds a list of texts with the configured embedding provider.

  The returned vectors are validated against `settings.embedding_dim`: writing a
  differently sized vector into the `vec0` virtual tables would corrupt the index, so a
  mismatch fails loudly instead (spec 10 章).
  """
  def embed(model, inputs, opts \\ []) when is_list(inputs) do
    setting = resolve_setting(Keyword.get(opts, :setting))
    provider = Keyword.get(opts, :provider) || embedding_provider(setting)
    expected_dim = Keyword.get(opts, :expected_dim) || embedding_dim(setting)

    with :ok <- check_api_key(provider, setting),
         {:ok, vectors} <-
           module(provider).embed(
             model,
             inputs,
             embedding_opts(provider, setting, opts, expected_dim)
           ) do
      validate_dimensions(vectors, expected_dim)
    end
  end

  @doc """
  Frees a resident model. Only Ollama exposes an unload API; every other provider is a
  no-op, so phase transitions can call this unconditionally (R-106/R-107).
  """
  def unload_model(model, opts \\ []) when is_binary(model) do
    setting = resolve_setting(Keyword.get(opts, :setting))
    provider = Keyword.get(opts, :provider) || generation_provider(setting)

    if normalize(provider) == "ollama" do
      Ollama.unload_model(model, provider_opts(provider, setting))
    else
      :ok
    end
  end

  @doc """
  Loads the embedding model and keeps it resident (R-104). Only meaningful for Ollama.
  """
  def prewarm_embedding(model, opts \\ []) when is_binary(model) do
    setting = resolve_setting(Keyword.get(opts, :setting))
    provider = embedding_provider(setting)

    if normalize(provider) == "ollama" do
      provider
      |> provider_opts(setting)
      |> Keyword.put(:keep_alive, -1)
      |> then(&Ollama.embed(model, ["prewarm"], &1))
      |> case do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  # --- Diagnostics ----------------------------------------------------------

  @doc """
  Checks connectivity for the provider backing `role`.
  """
  def health(role, setting \\ nil) when role in [:generation, :embedding] do
    setting = resolve_setting(setting)

    provider =
      if role == :generation, do: generation_provider(setting), else: embedding_provider(setting)

    case check_api_key(provider, setting) do
      :ok -> module(provider).health(provider_opts(provider, setting))
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists the models a provider reports as available.
  """
  def list_models(provider, setting \\ nil) do
    setting = resolve_setting(setting)
    module(provider).list_models(provider_opts(provider, setting))
  end

  @doc """
  Runs a minimal live request against the configured provider for `role` and returns a
  human readable result for the admin dashboard (F-807).
  """
  def connection_test(role, setting \\ nil) when role in [:generation, :embedding] do
    setting = resolve_setting(setting)

    case role do
      :generation ->
        provider = generation_provider(setting)
        model = generation_model(setting)

        case generate(model, "ping", setting: setting, max_tokens: 16, timeout: 30_000) do
          {:ok, _text} -> {:ok, "#{label(provider)} / #{model} に接続できました。"}
          {:error, reason} -> {:error, HTTP.describe(reason)}
        end

      :embedding ->
        provider = embedding_provider(setting)
        model = embedding_model(setting)

        case embed(model, ["ping"], setting: setting, timeout: 30_000) do
          {:ok, [vector | _]} ->
            {:ok, "#{label(provider)} / #{model} に接続できました (#{length(vector)} 次元)。"}

          {:ok, []} ->
            {:error, "ベクトルが返りませんでした。"}

          {:error, reason} ->
            {:error, HTTP.describe(reason)}
        end
    end
  end

  @doc "Configured generation model name."
  def generation_model(setting \\ nil) do
    setting |> resolve_setting() |> field(:batch_model, "ASK_DRIVE_LLM_MODEL", "qwen3:4b")
  end

  @doc "Configured embedding model name."
  def embedding_model(setting \\ nil) do
    setting |> resolve_setting() |> field(:embed_model, "ASK_DRIVE_EMBED_MODEL", "bge-m3")
  end

  @doc """
  Endpoint and credentials for a provider, as understood by the adapters.
  """
  def provider_opts(provider, setting \\ nil) do
    setting = resolve_setting(setting)

    [base_url: base_url(provider, setting), api_key: api_key(provider, setting)]
  end

  @doc """
  Base URL in effect for a provider, including defaults. Used by the settings screen to
  show what an empty field falls back to.
  """
  def base_url(provider, setting \\ nil) do
    setting = resolve_setting(setting)

    configured =
      case normalize(provider) do
        "ollama" -> get(setting, :ollama_host)
        "lmstudio" -> get(setting, :lmstudio_base_url)
        "openai" -> get(setting, :openai_base_url)
        "anthropic" -> get(setting, :anthropic_base_url)
        "gemini" -> get(setting, :gemini_base_url)
        _ -> nil
      end

    configured || default_base_url(provider)
  end

  @doc "Default endpoint for a provider when nothing is configured."
  def default_base_url(provider) do
    case normalize(provider) do
      "ollama" -> Ollama.default_base_url()
      "lmstudio" -> LMStudio.default_base_url()
      "openai" -> OpenAI.default_base_url(:openai)
      "anthropic" -> Anthropic.default_base_url()
      "gemini" -> Gemini.default_base_url()
      _ -> ""
    end
  end

  @doc """
  API key for a provider, from settings or the environment. Never log the return value.
  """
  def api_key(provider, setting \\ nil) do
    setting = resolve_setting(setting)

    case normalize(provider) do
      "openai" -> get(setting, :openai_api_key) || System.get_env("OPENAI_API_KEY")
      "anthropic" -> get(setting, :anthropic_api_key) || System.get_env("ANTHROPIC_API_KEY")
      "gemini" -> get(setting, :gemini_api_key) || System.get_env("GEMINI_API_KEY")
      _ -> nil
    end
  end

  @doc """
  Masked rendering of a stored API key for the settings screen (F-805).
  """
  def masked_api_key(provider, setting \\ nil) do
    case api_key(provider, setting) do
      key when is_binary(key) and byte_size(key) >= 4 ->
        "設定済み（末尾4文字: ..." <> String.slice(key, -4, 4) <> "）"

      key when is_binary(key) and key != "" ->
        "設定済み"

      _ ->
        "未設定"
    end
  end

  # --- Internals ------------------------------------------------------------

  defp order, do: ["ollama", "lmstudio", "gemini", "anthropic", "openai"]

  defp normalize(provider) when is_atom(provider) and not is_nil(provider),
    do: Atom.to_string(provider)

  defp normalize(provider) when is_binary(provider), do: String.downcase(String.trim(provider))
  defp normalize(_), do: @default_provider

  # Settings live in a singleton row that may not exist yet (fresh install, or a test that
  # never touched the DB), so every read tolerates its absence.
  defp resolve_setting(%{__struct__: _} = setting), do: setting

  defp resolve_setting(_) do
    Settings.get_setting()
  rescue
    _ -> nil
  end

  defp get(nil, _key), do: nil

  defp get(setting, key) do
    case Map.get(setting, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      value -> value
    end
  end

  defp field(setting, key, env_var, default) do
    get(setting, key) || System.get_env(env_var) || default
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      raw ->
        case Integer.parse(raw) do
          {value, _} when value > 0 -> value
          _ -> default
        end
    end
  end

  defp check_api_key(provider, setting) do
    if requires_api_key?(provider) and api_key(provider, setting) in [nil, ""] do
      {:error, {:unauthorized, "#{label(provider)} の API キーが未設定です。"}}
    else
      :ok
    end
  end

  defp generation_opts(provider, setting, opts) do
    provider
    |> provider_opts(setting)
    |> Keyword.merge(
      num_ctx: get(setting, :batch_num_ctx) || 4096,
      max_tokens: get(setting, :llm_max_tokens) || 4096,
      temperature: get(setting, :llm_temperature)
    )
    |> Keyword.merge(Keyword.take(opts, [:system, :num_ctx, :max_tokens, :temperature, :timeout]))
  end

  defp embedding_opts(provider, setting, opts, expected_dim) do
    provider
    |> provider_opts(setting)
    |> Keyword.put(:expected_dim, expected_dim)
    |> Keyword.merge(Keyword.take(opts, [:timeout, :keep_alive, :retry]))
  end

  defp validate_dimensions(vectors, expected_dim) do
    case Enum.find(vectors, &(length(&1) != expected_dim)) do
      nil ->
        {:ok, vectors}

      mismatched ->
        actual = length(mismatched)

        Logger.error(
          "Embedding dimension mismatch: expected #{expected_dim}, got #{actual}. " <>
            "埋め込みモデルと settings.embedding_dim の対応を確認してください。"
        )

        {:error, {:dimension_mismatch, expected: expected_dim, got: actual}}
    end
  end
end
