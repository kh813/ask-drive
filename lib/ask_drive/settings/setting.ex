defmodule AskDrive.Settings.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  alias AskDrive.Drive.ServiceAccount
  alias AskDrive.Encrypted.Binary

  @generation_providers ~w(ollama lmstudio gemini anthropic openai)
  @embedding_providers ~w(ollama lmstudio gemini openai)
  @drive_auth_modes ~w(oauth service_account)

  @api_key_fields [:openai_api_key, :anthropic_api_key, :gemini_api_key]
  @base_url_fields [
    :ollama_host,
    :lmstudio_base_url,
    :openai_base_url,
    :anthropic_base_url,
    :gemini_base_url
  ]

  schema "settings" do
    field :drive_folder_id, :string
    field :drive_folder_name, :string
    field :batch_start_hour, :integer, default: 0
    field :batch_end_hour, :integer, default: 7
    # Cut-off for a running batch (spec F-339); batch_end_hour only bounds the start
    field :batch_deadline_hour, :integer, default: 8
    field :batch_model, :string, default: "qwen3:4b"
    field :embed_model, :string, default: "bge-m3"
    field :batch_num_ctx, :integer, default: 4096
    # Legacy: was (mis)used as the Tier 1 cut-off; superseded by tier1_threshold
    field :similarity_threshold, :float, default: 0.65
    # Tier 1 (pre-generated QA) cosine-similarity cut-off, spec 6.4.1
    field :tier1_threshold, :float, default: 0.9
    field :serve_stale_qa, :boolean, default: false
    field :daytime_llm_enabled, :boolean, default: false
    field :chat_summary_enabled, :boolean, default: true
    # Nightly batch generation: "local" (llm_provider / batch_model) or "cloud"
    # (cloud_llm_provider / cloud_llm_model) — spec F-821
    field :batch_llm_mode, :string, default: "local"
    field :cloud_llm_provider, :string, default: "gemini"
    field :cloud_llm_model, :string
    # nil = same as llm_provider / batch_model (spec F-415)
    field :chat_summary_provider, :string
    field :chat_summary_model, :string
    field :allowed_domain, :string
    # first-access web setup (spec 6.12); set by AskDrive.Setup, not cast from forms
    field :setup_completed_at, :utc_datetime
    field :google_client_id, :string
    # Google login (OAuth) on/off (spec F-1310); Drive sync's OAuth is not affected
    field :oauth_login_enabled, :boolean, default: true
    field :google_client_secret, Binary
    field :maintenance_mode, :boolean, default: false
    # the nightly batch starts by itself (F-344); off while a new desk is being set up
    field :auto_batch_enabled, :boolean, default: true
    field :maintenance_message, :string

    # --- Drive sync authentication (spec 6.1, F-110) ---
    # "service_account" needs no browser OAuth round-trip, so it sidesteps Google's
    # redirect_uri/private-IP/.local restrictions entirely for the sync-only account.
    field :drive_auth_mode, :string, default: "oauth"
    field :drive_service_account_json, Binary
    # Domain-wide delegation: act as this Workspace user instead of the service account
    # itself, so org-only shared drives are readable (spec F-121).
    field :drive_impersonate_email, :string

    # Login required (spec F-1308); nil = not chosen yet (POC default). Set with
    # Settings.set_auth_required/1, never cast from forms.
    field :auth_required, :boolean

    # --- Sign-in with Google Secure LDAP (spec 6.13), platform-wide ---
    # Saved through Settings.update_ldap/2 (uploads + validation), not the general form.
    field :ldap_enabled, :boolean, default: false
    field :ldap_host, :string
    field :ldap_port, :integer
    field :ldap_base_dn, :string
    field :ldap_client_cert, Binary
    field :ldap_client_key, Binary
    field :ldap_ca_cert, :string
    field :ldap_bind_dn, :string
    field :ldap_bind_password, Binary

    # --- Administrator elevation (spec 6.2.1.1) ---
    # how long Platform Admin / a desk's admin screen stays open after confirming identity
    field :admin_session_minutes, :integer, default: 30

    # --- App Access Password (spec 6.11 F-1112) ---
    field :access_password_hash, :string
    field :access_password_enabled, :boolean, default: false

    # --- LLM providers (spec 6.2.2) ---
    field :llm_provider, :string, default: "ollama"
    field :embed_provider, :string, default: "ollama"
    field :embedding_dim, :integer, default: 1024
    field :llm_max_tokens, :integer, default: 4096
    field :llm_temperature, :float

    # --- Provider endpoints and credentials (spec 6.2.2.1) ---
    field :ollama_host, :string
    field :lmstudio_base_url, :string
    field :openai_api_key, Binary
    field :openai_base_url, :string
    field :anthropic_api_key, Binary
    field :anthropic_base_url, :string
    field :gemini_api_key, Binary
    field :gemini_base_url, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Provider identifiers accepted for text generation.
  """
  def generation_providers, do: @generation_providers

  @doc """
  Provider identifiers accepted for embedding. Claude has no embedding endpoint (F-803).
  """
  def embedding_providers, do: @embedding_providers

  @doc """
  Fields holding provider API keys.
  """
  def api_key_fields, do: @api_key_fields

  @doc """
  Every encrypted secret. A blank submission for these keeps the stored value, so the form
  never has to echo a secret back just to survive a round trip (N-610).
  """
  def secret_fields, do: [:google_client_secret, :drive_service_account_json | @api_key_fields]

  @doc """
  Accepted values for `drive_auth_mode`.
  """
  def drive_auth_modes, do: @drive_auth_modes

  @doc """
  Sign-in with LDAP (spec 6.13). Validates the client certificate and key as a pair whenever
  either changes, and requires them (and a base DN, explicit or from the domain) to enable.
  """
  def ldap_changeset(setting, attrs) do
    changeset =
      setting
      |> cast(attrs, [
        :ldap_enabled,
        :ldap_host,
        :ldap_port,
        :ldap_base_dn,
        :ldap_client_cert,
        :ldap_client_key,
        :ldap_ca_cert,
        :ldap_bind_dn,
        :ldap_bind_password
      ])
      |> validate_number(:ldap_port, greater_than: 0, less_than: 65_536)

    cert = get_field(changeset, :ldap_client_cert)
    key = get_field(changeset, :ldap_client_key)

    changeset =
      if (changed?(changeset, :ldap_client_cert) or changed?(changeset, :ldap_client_key)) and
           present?(cert) and present?(key) do
        case AskDrive.SSL.validate_client_pair(cert, key) do
          {:ok, _info} -> changeset
          {:error, messages} -> add_error(changeset, :ldap_client_cert, Enum.join(messages, "／"))
        end
      else
        changeset
      end

    if get_field(changeset, :ldap_enabled) do
      changeset
      |> check_present(cert, :ldap_client_cert, "有効にするにはクライアント証明書が必要です")
      |> check_present(key, :ldap_client_key, "有効にするには秘密鍵が必要です")
      |> check_present(
        AskDrive.Ldap.base_dn(apply_changes(changeset)),
        :ldap_base_dn,
        "ベース DN を入力するか、組織の Google Workspace ドメインを設定してください"
      )
    else
      changeset
    end
  end

  defp check_present(changeset, value, field, message) do
    if present?(value), do: changeset, else: add_error(changeset, field, message)
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(
      attrs,
      [
        :drive_folder_id,
        :drive_folder_name,
        :google_client_id,
        :google_client_secret,
        :oauth_login_enabled,
        :batch_start_hour,
        :batch_end_hour,
        :batch_deadline_hour,
        :batch_model,
        :embed_model,
        :batch_num_ctx,
        :similarity_threshold,
        :tier1_threshold,
        :serve_stale_qa,
        :daytime_llm_enabled,
        :chat_summary_enabled,
        :batch_llm_mode,
        :cloud_llm_provider,
        :cloud_llm_model,
        :chat_summary_provider,
        :chat_summary_model,
        :allowed_domain,
        :maintenance_mode,
        :auto_batch_enabled,
        :maintenance_message,
        :drive_auth_mode,
        :drive_service_account_json,
        :drive_impersonate_email,
        :admin_session_minutes,
        :llm_provider,
        :embed_provider,
        :embedding_dim,
        :llm_max_tokens,
        :llm_temperature
      ] ++ @api_key_fields ++ @base_url_fields
    )
    |> validate_required([
      :batch_start_hour,
      :batch_end_hour,
      :batch_model,
      :embed_model,
      :batch_num_ctx,
      :similarity_threshold,
      :llm_provider,
      :embed_provider,
      :embedding_dim
    ])
    |> validate_number(:batch_start_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:batch_end_hour, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:batch_deadline_hour,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 23
    )
    |> validate_number(:tier1_threshold,
      greater_than_or_equal_to: 0.5,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:similarity_threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:batch_num_ctx, greater_than: 512)
    |> validate_inclusion(:llm_provider, @generation_providers, message: "は対応していないプロバイダです")
    |> validate_inclusion(:embed_provider, @embedding_providers,
      message: "は埋め込みに対応していません（Claude API には埋め込みエンドポイントがありません）"
    )
    |> validate_number(:embedding_dim, greater_than_or_equal_to: 64, less_than_or_equal_to: 4096)
    |> validate_number(:llm_max_tokens, greater_than: 0, less_than_or_equal_to: 200_000)
    |> validate_number(:llm_temperature,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:admin_session_minutes,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 480
    )
    |> validate_inclusion(:drive_auth_mode, @drive_auth_modes, message: "は対応していない認証方式です")
    |> validate_base_urls()
    |> validate_chat_summary_provider()
    |> update_change(:allowed_domain, &normalize_domain/1)
    |> validate_format(
      :allowed_domain,
      ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/,
      message: "はドメイン名（例: company.com）で入力してください"
    )
    |> validate_batch_llm_mode()
    |> validate_drive_service_account()
    |> update_change(:drive_impersonate_email, &(&1 && String.trim(&1)))
    |> validate_format(:drive_impersonate_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "はメールアドレスの形式で入力してください"
    )
  end

  defp validate_base_urls(changeset) do
    Enum.reduce(@base_url_fields, changeset, fn field, acc ->
      case get_change(acc, field) do
        nil ->
          acc

        "" ->
          acc

        url ->
          if String.starts_with?(url, ["http://", "https://"]) do
            acc
          else
            add_error(acc, field, "は http:// または https:// で始まる URL を指定してください")
          end
      end
    end)
  end

  # A provider without its API key is allowed (the key may not be issued yet, spec F-343):
  # the admin screen says it is missing, and the nightly batch skips the run and records why
  # instead of starting one it cannot finish.

  # A service account key is only usable once it actually parses; catching a malformed
  # paste here (missing client_email/private_key, broken JSON) beats discovering it during
  # the nightly sync, hours after anyone was watching (spec 10 章).
  defp validate_drive_service_account(changeset) do
    json = get_field(changeset, :drive_service_account_json)

    cond do
      get_field(changeset, :drive_auth_mode) != "service_account" ->
        changeset

      # A key is required when a save sets (or clears) the key in service-account mode, not
      # for every save afterwards: a new app starts in this mode without a key (spec 6.11)
      # and must still be able to save its other settings.
      blank?(json) and Map.has_key?(changeset.changes, :drive_service_account_json) ->
        add_error(
          changeset,
          :drive_service_account_json,
          "Drive 認証方式にサービスアカウントを選んだため、JSON キーが必要です"
        )

      blank?(json) ->
        changeset

      match?({:error, _}, ServiceAccount.parse(json)) ->
        {:error, reason} = ServiceAccount.parse(json)
        add_error(changeset, :drive_service_account_json, reason)

      true ->
        changeset
    end
  end

  @cloud_providers ~w(gemini anthropic openai)

  # Cloud mode needs a cloud provider, its API key and a model name; local mode is validated
  # by the existing llm_provider rules.
  defp validate_batch_llm_mode(changeset) do
    changeset = validate_inclusion(changeset, :batch_llm_mode, ["local", "cloud"])

    if get_field(changeset, :batch_llm_mode) == "cloud" do
      changeset
      |> validate_inclusion(:cloud_llm_provider, @cloud_providers, message: "はクラウドのプロバイダを選んでください")
      |> then(fn cs ->
        if blank?(get_field(cs, :cloud_llm_model)),
          do: add_error(cs, :cloud_llm_model, "クラウドで実行する場合はモデル名を指定してください"),
          else: cs
      end)
    else
      changeset
    end
  end

  def cloud_providers, do: @cloud_providers

  # "@Company.com " -> "company.com"
  def normalize_domain(nil), do: nil

  def normalize_domain(domain) when is_binary(domain),
    do: domain |> String.trim() |> String.trim_leading("@") |> String.downcase()

  # The chat summary may run on its own provider; when it does, it needs that provider's key
  # and an explicit model name (the batch model belongs to the other provider).
  defp validate_chat_summary_provider(changeset) do
    provider = get_field(changeset, :chat_summary_provider)

    if blank?(provider) do
      changeset
    else
      changeset
      |> validate_inclusion(:chat_summary_provider, @generation_providers,
        message: "は対応していないプロバイダです"
      )
      |> then(fn cs ->
        if provider != get_field(cs, :llm_provider) and blank?(get_field(cs, :chat_summary_model)) do
          add_error(cs, :chat_summary_model, "チャット要約プロバイダを回答生成と別にする場合は、モデル名を指定してください")
        else
          cs
        end
      end)
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
