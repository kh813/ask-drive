defmodule AskDrive.LLM.CloudModels do
  @moduledoc """
  The models a cloud API (Gemini / Claude / OpenAI) offers for text generation, for the
  model pull-down of a desk's AI settings (spec F-834).

  Asked from the provider with the desk's saved API key, so the list follows the provider's
  releases without an AskDrive update. A list is kept for 6 hours per
  provider, endpoint and key (a changed key or endpoint asks again); "Refresh list" asks again
  at once. Failures are not kept.
  """
  use Gettext, backend: AskDriveWeb.Gettext

  alias AskDrive.LLM
  alias AskDrive.LLM.HTTP
  alias AskDrive.LLM.Providers.{Anthropic, Gemini, OpenAI}

  @ttl_ms 6 * 3600 * 1000

  # Gemini's text generation models as its manual lists them
  # (https://ai.google.dev/gemini-api/docs/models, 2026-10-15; shut-down, agent, Live, TTS,
  # image and embedding models left out). Only offered as suggestions when the API key may
  # not list models itself (F-834), so a stale entry costs little: any name can be typed.
  @gemini_documented [
    {"gemini-4-argon", "Gemini 4 Argon"},
    {"gemini-3.8-flash", "Gemini 3.8 Flash"},
    {"gemini-3.6-flash", "Gemini 3.6 Flash"},
    {"gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite"},
    {"gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite"},
    {"gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"},
    {"gemini-3-flash-preview", "Gemini 3 Flash (preview)"},
    {"gemini-2.5-pro", "Gemini 2.5 Pro"},
    {"gemini-2.5-flash", "Gemini 2.5 Flash"},
    {"gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite"}
  ]

  @doc "The models of `provider`'s manual, offered when its API can't be asked (F-834)."
  def documented(provider) when provider in ~w(gemini vertex), do: @gemini_documented
  def documented(_provider), do: []

  @doc """
  `{:ok, [{id, label}]}` — the provider's text generation models —, `{:documented, [{id,
  label}], why}` — the models of the provider's manual, when the API key may not list models
  (`:blocked`) or the provider has no list for one (`:no_list`, Agent Platform) — or
  `{:error, message}` (no API key saved, or the provider couldn't be asked). `force: true`
  skips the kept list.
  """
  def list(provider, setting, opts \\ []) do
    api_key = LLM.api_key(provider, setting)

    cond do
      # Agent Platform lists no models for an API key: the Gemini manual's are suggested
      provider == "vertex" ->
        {:documented, documented("vertex"), :no_list}

      provider not in ~w(gemini anthropic openai) ->
        {:error, gettext("%{provider} has no model list.", provider: to_string(provider))}

      api_key in [nil, ""] ->
        {:error,
         gettext("Save the %{provider} API key to choose from its models.",
           provider: LLM.label(provider)
         )}

      true ->
        opts_for_provider = LLM.provider_opts(provider, setting)
        key = {__MODULE__, provider, cache_digest(opts_for_provider)}

        case cached(key, Keyword.get(opts, :force, false)) do
          {:ok, models} ->
            {:ok, models}

          :miss ->
            case fetch(provider, opts_for_provider) do
              {:ok, models} ->
                :persistent_term.put(key, {System.monotonic_time(:millisecond), models})
                {:ok, models}

              # the key's restrictions leave out listing: the manual's models as suggestions
              {:error, {:list_blocked, _}} ->
                {:documented, documented(provider), :blocked}

              {:error, reason} ->
                {:error,
                 gettext("Could not get the model list: %{reason}",
                   reason: HTTP.describe(reason)
                 )}
            end
        end
    end
  end

  defp fetch("gemini", opts), do: Gemini.list_generation_models(opts)
  defp fetch("anthropic", opts), do: Anthropic.list_generation_models(opts)
  defp fetch("openai", opts), do: OpenAI.list_generation_models(opts)

  defp cached(_key, true), do: :miss

  defp cached(key, false) do
    case :persistent_term.get(key, nil) do
      {at, models} ->
        if System.monotonic_time(:millisecond) - at < @ttl_ms, do: {:ok, models}, else: :miss

      nil ->
        :miss
    end
  end

  # the key itself is never kept, only a digest of it with the endpoint
  defp cache_digest(opts) do
    :crypto.hash(:sha256, [to_string(opts[:base_url]), 0, to_string(opts[:api_key])])
  end

  @doc """
  The pull-down options for `models` with `current` (the saved model name) selected: a saved
  name the provider no longer lists is kept as an option of its own, so saving the form
  doesn't silently change the model.
  """
  def options(models, current) do
    options =
      Enum.map(models, fn
        {id, label} when label in [nil, "", id] -> {id, id}
        {id, label} -> {"#{label} (#{id})", id}
      end)

    if current in [nil, ""] or Enum.any?(models, fn {id, _} -> id == current end),
      do: options,
      else: [{gettext("%{model} (not in the list)", model: current), current} | options]
  end
end
