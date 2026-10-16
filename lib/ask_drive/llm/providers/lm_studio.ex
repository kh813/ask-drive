defmodule AskDrive.LLM.Providers.LMStudio do
  @moduledoc """
  LM Studio adapter (spec 3.6.2). LM Studio exposes an OpenAI-compatible server, so this
  module is a thin flavor of `AskDrive.LLM.Providers.OpenAI`.

  Unlike Ollama it offers no `keep_alive` equivalent, so model residency is left to LM
  Studio's own auto-unload setting and the phase transitions skip it (R-106/R-107).
  """
  @behaviour AskDrive.LLM.Provider

  alias AskDrive.LLM.Providers.OpenAI

  @impl true
  def local?, do: true

  @impl true
  def supports_embedding?, do: true

  @impl true
  def generate(model, prompt, opts \\ []), do: OpenAI.generate(model, prompt, flavored(opts))

  @impl true
  def embed(model, inputs, opts \\ []), do: OpenAI.embed(model, inputs, flavored(opts))

  @impl true
  def list_models(opts \\ []), do: OpenAI.list_models(flavored(opts))

  @impl true
  def health(opts \\ []), do: OpenAI.health(flavored(opts))

  @doc """
  Default endpoint used when neither settings nor `LMSTUDIO_BASE_URL` provide one.
  """
  def default_base_url, do: OpenAI.default_base_url(:lmstudio)

  defp flavored(opts), do: Keyword.put(opts, :flavor, :lmstudio)
end
