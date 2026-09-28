defmodule AskDrive.Settings do
  @moduledoc """
  Context for managing application settings (singleton).

  Defaults are seeded from the environment on first read, so a fresh install configured by
  `scripts/initial-setup.sh` works before anyone opens the admin screen (spec 6.2.2.1).
  """
  import Ecto.Query, warn: false

  alias AskDrive.Repo
  alias AskDrive.Settings.Setting

  @doc """
  Gets the singleton setting record. If none exists, creates and returns the default setting.
  """
  def get_setting! do
    case Repo.one(from s in Setting, limit: 1) do
      nil ->
        {:ok, setting} =
          %Setting{}
          |> Setting.changeset(default_attrs())
          |> seed_admin_password()
          |> Repo.insert()

        setting

      setting ->
        setting
    end
  end

  # `ASK_DRIVE_ADMIN_PASSWORD` is a setup convenience: it is hashed once into the singleton
  # and never read again, so the plaintext does not have to live in the environment
  # long-term (spec 6.9.4). Applied outside the changeset because the hash is derived, not
  # user input.
  defp seed_admin_password(changeset) do
    case System.get_env("ASK_DRIVE_ADMIN_PASSWORD") do
      password when is_binary(password) and byte_size(password) > 0 ->
        Ecto.Changeset.put_change(
          changeset,
          :admin_password_hash,
          AskDrive.Accounts.AdminAccess.hash_password(password)
        )

      _ ->
        changeset
    end
  end

  @doc """
  The platform's settings (the primary app's row in the platform database), whichever app
  the calling process serves. For platform-wide values: Google sign-in credentials, allowed
  domain, administrator password and sessions, the nightly batch window (spec 6.11).
  """
  def platform_setting!, do: AskDrive.Apps.platform(&get_setting!/0)
  def platform_setting, do: AskDrive.Apps.platform(&get_setting/0)

  @doc """
  Gets the singleton setting record (nullable).
  """
  def get_setting do
    Repo.one(from s in Setting, limit: 1)
  end

  @doc """
  Updates the singleton setting.

  Blank secret fields are dropped rather than written, so re-saving the form without
  re-typing an API key or the OAuth client secret keeps the stored value (spec 9.6 N-610).
  """
  def update_setting(%Setting{} = setting, attrs) do
    setting
    |> Setting.changeset(drop_blank_secrets(attrs))
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking setting changes.
  """
  def change_setting(%Setting{} = setting, attrs \\ %{}) do
    Setting.changeset(setting, drop_blank_secrets(attrs))
  end

  @doc """
  Whether the submitted attributes would change the embedding model or dimension. Such a
  change invalidates every stored vector and requires a full re-index (F-809).
  """
  def reindex_required?(%Setting{} = setting, attrs) do
    changed?(setting.embed_model, attrs, "embed_model") or
      changed?(setting.embedding_dim, attrs, "embedding_dim")
  end

  defp changed?(current, attrs, key) do
    case fetch_attr(attrs, key) do
      :error -> false
      {:ok, value} -> to_string(value) != to_string(current)
    end
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> :error
  end

  defp drop_blank_secrets(attrs) when is_map(attrs) do
    Enum.reduce(Setting.secret_fields(), attrs, fn field, acc ->
      acc
      |> Map.drop(blank_keys(acc, field))
    end)
  end

  defp drop_blank_secrets(attrs), do: attrs

  defp blank_keys(attrs, field) do
    [Atom.to_string(field), field]
    |> Enum.filter(fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} when is_binary(value) -> String.trim(value) == ""
        {:ok, nil} -> true
        _ -> false
      end
    end)
  end

  defp default_attrs do
    %{
      batch_start_hour: 0,
      batch_end_hour: 7,
      batch_model: System.get_env("ASK_DRIVE_LLM_MODEL") || "qwen3:4b",
      embed_model: System.get_env("ASK_DRIVE_EMBED_MODEL") || "bge-m3",
      batch_num_ctx: 4096,
      similarity_threshold: 0.65,
      serve_stale_qa: false,
      daytime_llm_enabled: false,
      llm_provider: System.get_env("ASK_DRIVE_LLM_PROVIDER") || "ollama",
      embed_provider: System.get_env("ASK_DRIVE_EMBED_PROVIDER") || "ollama",
      embedding_dim: env_integer("ASK_DRIVE_EMBEDDING_DIM", 1024),
      llm_max_tokens: 4096,
      allowed_domain: System.get_env("ASK_DRIVE_ALLOWED_DOMAIN"),
      google_client_id: System.get_env("GOOGLE_CLIENT_ID"),
      google_client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
      openai_api_key: System.get_env("OPENAI_API_KEY"),
      anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
      gemini_api_key: System.get_env("GEMINI_API_KEY"),
      ollama_host: System.get_env("OLLAMA_HOST"),
      lmstudio_base_url: System.get_env("LMSTUDIO_BASE_URL")
    }
  end

  defp env_integer(name, default) do
    with raw when is_binary(raw) <- System.get_env(name),
         {value, _rest} when value > 0 <- Integer.parse(raw) do
      value
    else
      _ -> default
    end
  end
end
