defmodule AskDrive.Batch.ItemLog do
  @moduledoc """
  Per-file record of what a batch did with each Drive file (spec 6.3.5).

  Phase-level counters (`BatchPhaseStat`) only say how many items a phase touched; they can't
  say that sync found 4 files and every one of them then failed to export. These rows can:
  one per file per phase, with the outcome, the chunk count, the time taken and the reason.

  Statuses:
    * sync: `created` / `updated` / `unchanged` / `deleted` / `failed` (and a single
      `failed` row without a file when the folder itself could not be listed)
    * embed_chunks: `indexed` / `unchanged` / `empty` / `skipped` / `failed`

  Logging never breaks a batch: a failed insert is logged and swallowed.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false
  require Logger

  alias AskDrive.Repo

  @statuses ~w(created updated unchanged deleted indexed empty skipped failed)

  schema "batch_item_logs" do
    belongs_to :batch_run, AskDrive.Batch.BatchRun
    field :phase, :string
    field :document_id, :integer
    field :drive_file_id, :string
    field :name, :string
    field :mime_type, :string
    field :status, :string
    field :chunks, :integer
    field :message, :string
    field :duration_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :batch_run_id,
      :phase,
      :document_id,
      :drive_file_id,
      :name,
      :mime_type,
      :status,
      :chunks,
      :message,
      :duration_ms
    ])
    |> validate_required([:phase, :status])
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Records one item. `batch_run_id` may be nil (a worker run outside a batch), in which case
  nothing is stored — there is no batch screen to show it on.
  """
  def record(nil, _attrs), do: :ok

  def record(batch_run_id, attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :batch_run_id, batch_run_id))
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "ItemLog: could not record #{inspect(attrs)}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("ItemLog: could not record #{inspect(attrs)}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  All rows for a batch, failures first, then in the order they happened.
  """
  def list_for_run(batch_run_id) do
    Repo.all(
      from l in __MODULE__,
        where: l.batch_run_id == ^batch_run_id,
        order_by: [
          desc: fragment("CASE WHEN ? = 'failed' THEN 1 ELSE 0 END", l.status),
          asc: l.id
        ]
    )
  end

  @doc """
  Per-run totals for the history table: `%{run_id => %{indexed: n, chunks: n, failed: n}}`.
  """
  def summaries([]), do: %{}

  def summaries(run_ids) do
    Repo.all(
      from l in __MODULE__,
        where: l.batch_run_id in ^run_ids,
        group_by: l.batch_run_id,
        select:
          {l.batch_run_id,
           %{
             indexed:
               sum(
                 fragment(
                   "CASE WHEN ? = 'embed_chunks' AND ? = 'indexed' THEN 1 ELSE 0 END",
                   l.phase,
                   l.status
                 )
               ),
             chunks:
               sum(
                 fragment(
                   "CASE WHEN ? = 'embed_chunks' AND ? = 'indexed' THEN COALESCE(?, 0) ELSE 0 END",
                   l.phase,
                   l.status,
                   l.chunks
                 )
               ),
             failed: sum(fragment("CASE WHEN ? = 'failed' THEN 1 ELSE 0 END", l.status))
           }}
    )
    |> Map.new()
  end

  @doc """
  Turns an error term from Drive/extraction/embedding into one readable line. Drive answers
  a file the caller may not read with 404, so say that rather than "not found".
  """
  def describe_reason("HTTP 404" <> _),
    do: "Drive: ファイルが見つからないか、同期アカウントに閲覧権限がありません (HTTP 404)"

  def describe_reason("HTTP 403" <> rest = raw) do
    if String.contains?(rest, "cannotDownloadFile") do
      "Drive: 閲覧はできるがダウンロードが禁止されています (cannotDownloadFile)。" <>
        "共有ドライブの「閲覧者と閲覧者（コメント可）にファイルのダウンロード、印刷、コピーを許可」を有効にするか、" <>
        "同期ユーザーを「投稿者」以上にするか、ファイルの共有設定（歯車）で「閲覧者と閲覧者（コメント可）に、ダウンロード、印刷、コピーの項目を表示する」を有効にしてください"
    else
      describe_generic_403(raw)
    end
  end

  def describe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 1000)
  def describe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def describe_reason(reason), do: reason |> inspect() |> String.slice(0, 1000)

  defp describe_generic_403(raw),
    do: "Drive: アクセスが拒否されました (HTTP 403) — #{String.slice(raw, 0, 300)}"
end
