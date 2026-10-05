defmodule AskDrive.Batch.Scheduler do
  @moduledoc """
  Orchestrates the 6-phase Nightly Batch pipeline:

  1. Phase 1: Sync (Drive metadata sync, extract & chunking) - No LLM, never aborted.
  2. Phase 2: Invalidate (Mark stale QAs, summaries, extractions for modified docs) - No LLM.
  3. Phase 3: Embed Chunks (Embed newly added or modified document chunks) - Embed model only.
  4. Phase 4: Generate (QA generation, summaries, extractions) - Generation model only (Budget & Deadline controlled).
  5. Phase 5: Embed Questions (Embed newly generated hypothetical questions) - Embed model only.
  6. Phase 6: Verify & Stats (Consistency check, update batch_runs & stats) - No LLM.

  Enforces strict single-model residency per phase:
  - Embed model loaded during Phase 3 & 5.
  - Batch generation model loaded during Phase 4.
  - All models unloaded or transitioned to daytime mode upon completion.
  """
  require Logger
  import Ecto.Query, warn: false

  alias AskDrive.Documents.Chunk
  alias AskDrive.QA.QAPair
  alias AskDrive.{QA, Repo, Settings}

  alias AskDrive.Batch.{
    BatchPhaseStat,
    BatchRun,
    EmbedChunksWorker,
    EmbedQuestionsWorker,
    ItemLog,
    Progress,
    SyncWorker
  }

  alias AskDrive.Generate.{Extraction, QA, Summary}
  alias AskDrive.LLM
  alias AskDrive.Runtime.Mode

  @doc """
  Whether a batch is currently running. Batches run inside this process, so two at once
  would fight over the single local model and the same documents.
  """
  def running? do
    Repo.exists?(from b in BatchRun, where: b.status == "running")
  end

  @doc """
  Asks this app's running batch to stop (spec F-341). It stops at the next item boundary —
  after the file, document or chunk in progress — and is recorded as "stopped". A stopped
  automatic run counts as this night's run, so the window doesn't start it again.
  """
  def request_stop do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Repo.update_all(
        from(b in BatchRun, where: b.status == "running" and is_nil(b.stop_requested_at)),
        set: [stop_requested_at: now]
      )

    # one waiting for its turn to generate (F-355) stops right away: it never gets the turn
    {waiting, _} =
      Repo.update_all(
        from(b in BatchRun, where: b.status == "waiting"),
        set: [stop_requested_at: now, status: "stopped", finished_at: now]
      )

    if count + waiting > 0, do: :ok, else: {:error, :not_running}
  end

  @doc """
  Whether any app's batch is running (they share one local model; spec 6.11), or the
  nightly batch is going through the desks (F-355).
  """
  def running_anywhere? do
    AskDrive.Batch.Night.running?() or any_app_running?()
  end

  defp any_app_running? do
    AskDrive.Apps.each(fn _app -> running?() end) |> Enum.any?(fn {_app, r} -> r end)
  end

  @doc """
  Whether an automatic full batch has run at or after `since` (UTC). Manual runs don't count
  (F-330). A batch cut off by a restart ("aborted", e.g. a deploy during the night) doesn't
  count either, so the night window starts it again; a "failed" one does, so a persistent
  failure isn't retried every minute.
  """
  def ran_since?(%DateTime{} = since) do
    Repo.exists?(
      from b in BatchRun,
        where:
          b.kind == "full" and b.trigger == "auto" and b.started_at >= ^since and
            b.status != "aborted"
    )
  end

  @doc """
  Runs the entire 6-phase batch process synchronously.
  Can be invoked by Oban Cron or manually from Admin dashboard.

  `ingest_only: true` runs only sync and indexing (phases 1-3, then 6) and never loads the
  generation model (spec 6.3.8 F-331). Meant for daytime manual runs: a full batch spends
  hours generating QA with the local model, and chat query embeddings queue behind it.
  It also stays out of `:night_batch`, so the embedding model stays resident for chat.

  Used by the nightly batch (`AskDrive.Batch.Night`, F-355): `stage: :ingest` runs phases
  1-3 and leaves the run "waiting" for `resume_batch/2` to generate; `deadline:` sets when
  generation stops (default: the night's cut-off, `calculate_deadline/2`); `night: true`
  lets it run while the nightly batch itself is what is going on.
  """
  def run_batch(opts \\ []) do
    # The nightly cron and a manual run — in this app or another — could otherwise overlap
    # and fight over the one local model.
    busy? = if Keyword.get(opts, :night), do: any_app_running?(), else: running_anywhere?()

    cond do
      busy? ->
        Logger.warning("Batch requested while another is running; skipped")
        {:error, :already_running}

      provider = LLM.missing_api_key(:embedding) ->
        record_skipped(
          opts,
          "埋め込み（#{provider}）の API キーが未設定のため、実行しませんでした。窓口の管理画面の「設定」で API キーを登録してください。"
        )

      true ->
        do_run_batch(opts)
    end
  rescue
    # A crash before the batch_runs row exists (or outside the phases' own rescue) used to
    # vanish into a Task's log line; the night then looked as if nothing had been tried.
    # Record it as a failed run so the history shows the attempt and the reason (F-338).
    e ->
      Logger.error("Batch crashed: #{Exception.format(:error, e, __STACKTRACE__)}")

      %BatchRun{}
      |> BatchRun.changeset(%{
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        status: "failed",
        kind: if(Keyword.get(opts, :ingest_only, false), do: "ingest_only", else: "full"),
        trigger: if(Keyword.get(opts, :trigger) == "auto", do: "auto", else: "manual"),
        error: Exception.message(e)
      })
      |> Repo.insert()

      Mode.end_batch()
      {:error, e}
  end

  @doc "Recent batch runs, newest first, with their phase stats."
  def list_runs(limit \\ 20) do
    Repo.all(
      from b in BatchRun,
        order_by: [desc: b.started_at, desc: b.id],
        limit: ^limit,
        preload: [:phase_stats]
    )
  end

  @doc """
  What the night-window trigger will do, for the admin screen (spec F-338):
  `%{window: {start_h, end_h}, window_start: local, in_window?: bool,
  state: :running | :off | :done | :due | :missed, run: run | nil, next_start: local}`
  (`:off`: this desk's automatic run is switched off, F-344).
  """
  def auto_status(now \\ AskDrive.Clock.local_now()) do
    # the window is platform-wide; the runs are this app's
    setting = Settings.platform_setting!()
    start_h = setting.batch_start_hour || 0
    end_h = setting.batch_end_hour || 7
    window_start = Mode.night_window_start_utc(now)
    in_window? = Mode.calculate_current_mode(now) == :night_batch

    tonight =
      Repo.one(
        from b in BatchRun,
          where:
            b.kind == "full" and b.trigger == "auto" and b.started_at >= ^window_start and
              b.status != "aborted",
          order_by: [desc: b.started_at],
          limit: 1
      )

    today_start = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(start_h, 0, 0))

    next_start =
      if NaiveDateTime.compare(now, today_start) == :lt,
        do: today_start,
        else: NaiveDateTime.add(today_start, 86_400)

    # :done covers "this window" while inside it and "last night" in the daytime;
    # :missed means last night's window closed without a (non-aborted) full batch.
    state =
      cond do
        running_anywhere?() -> :running
        Settings.get_setting!().auto_batch_enabled == false -> :off
        tonight -> :done
        in_window? -> :due
        true -> :missed
      end

    %{
      window: {start_h, end_h},
      deadline_hour: setting.batch_deadline_hour || 8,
      window_start: AskDrive.Clock.to_local(window_start),
      in_window?: in_window?,
      state: state,
      run: tonight,
      next_start: next_start
    }
  end

  # Nothing can be indexed without the embedding provider's key (e.g. not issued yet, spec
  # F-343): record the night as skipped, with why, instead of marking every document failed.
  # A skipped automatic run counts as the night's run, so it isn't retried every minute.
  defp record_skipped(opts, reason) do
    Logger.warning("Batch skipped: #{reason}")
    now = DateTime.utc_now()

    %BatchRun{}
    |> BatchRun.changeset(%{
      started_at: now,
      finished_at: now,
      status: "skipped",
      error: reason,
      kind: if(Keyword.get(opts, :ingest_only, false), do: "ingest_only", else: "full"),
      trigger: if(Keyword.get(opts, :trigger) == "auto", do: "auto", else: "manual")
    })
    |> Repo.insert()
  end

  defp do_run_batch(opts) do
    ingest_only? = Keyword.get(opts, :ingest_only, false)
    setting = Settings.get_setting!()

    # 1. Create batch_run record
    {:ok, batch_run} =
      %BatchRun{}
      |> BatchRun.changeset(%{
        started_at: DateTime.utc_now(),
        status: "running",
        model_used: "#{LLM.generation_provider(setting)}:#{LLM.generation_model(setting)}",
        chunks_processed: 0,
        qa_generated: 0,
        qa_invalidated: 0,
        questions_resolved: 0,
        kind: if(ingest_only?, do: "ingest_only", else: "full"),
        trigger: Keyword.get(opts, :trigger, "manual")
      })
      |> Repo.insert()

    in_run(batch_run, setting, opts, fn batch_run, deadline ->
      # --- Phase 1: Sync ---
      {_p1_stat, batch_run} = run_phase_1_sync(batch_run, setting)

      # --- Phase 2: Invalidate ---
      {_p2_stat, batch_run} = run_phase_2_invalidate(batch_run, setting)

      # --- Phase 3: Embed Chunks ---
      {_p3_stat, batch_run} = run_phase_3_embed_chunks(batch_run, setting)

      if Keyword.get(opts, :stage) == :ingest and not ingest_only? do
        # the nightly batch imports every desk before any generates (F-355)
        Progress.detail("ほかの窓口の取り込みが終わるのを待っています（このあと想定QAを生成します）")

        {:ok, batch_run |> BatchRun.changeset(%{status: "waiting"}) |> Repo.update!()}
      else
        finish_run(batch_run, setting, deadline, opts)
      end
    end)
  end

  @doc """
  Generates for a run left "waiting" by `run_batch(stage: :ingest)` (phases 4-6), with
  generation cut off at `deadline:` (F-355). `{:error, :not_waiting}` if it no longer
  waits (stopped in the meantime).
  """
  def resume_batch(run_id, opts \\ []) do
    case Repo.get(BatchRun, run_id) do
      %BatchRun{status: "waiting"} = run ->
        run = run |> BatchRun.changeset(%{status: "running"}) |> Repo.update!()
        setting = Settings.get_setting!()
        in_run(run, setting, opts, &finish_run(&1, setting, &2, opts))

      _ ->
        {:error, :not_waiting}
    end
  rescue
    e ->
      Logger.error("Batch resume crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:error, e}
  end

  # Phases 4-6: generate (unless ingest-only or without a generation key), then finish
  defp finish_run(batch_run, setting, deadline, opts) do
    ingest_only? = batch_run.kind == "ingest_only"
    missing_generation_key = LLM.missing_api_key(:generation, setting)

    {batch_run, deadline_reached?} =
      cond do
        ingest_only? ->
          Logger.info("Batch ##{batch_run.id} - ingest only: skipping Phase 4 (Generate) and 5")
          {batch_run, false}

        # the embedding key is there but not the generation one (spec F-343): index, and
        # say why no QA was generated
        missing_generation_key ->
          note =
            "生成（#{missing_generation_key}）の API キーが未設定のため、QA 生成を行いませんでした（取り込みのみ実行）。"

          Logger.warning("Batch ##{batch_run.id} - #{note}")
          {batch_run |> BatchRun.changeset(%{error: note}) |> Repo.update!(), false}

        true ->
          # --- Phase 4: Generate (Deadline-controlled) ---
          batch_run =
            batch_run |> BatchRun.changeset(%{generation_deadline: deadline}) |> Repo.update!()

          {_p4_stat, batch_run, deadline_reached?} =
            run_phase_4_generate(batch_run, setting, deadline, Keyword.get(opts, :force, false))

          # --- Phase 5: Embed Questions ---
          {_p5_stat, batch_run} = run_phase_5_embed_questions(batch_run, setting)
          {batch_run, deadline_reached?}
      end

    # --- Phase 6: Verify & Finish ---
    {_p6_stat, batch_run} = run_phase_6_verify(batch_run, setting, deadline_reached?)
    {:ok, batch_run}
  end

  # Runs `fun.(batch_run, deadline)` as the run's process: progress reports go to the run,
  # the machine stays awake, and a failure or a stop request is recorded on the run.
  defp in_run(batch_run, setting, opts, fun) do
    ingest_only? = batch_run.kind == "ingest_only"

    # progress reports from this process (and the workers it calls) go to this run (F-340)
    Progress.bind(batch_run.id)

    # Transition runtime mode into night_batch (a full batch only: ingest-only never loads the
    # generation model, and the daytime mode keeps the embedding model resident for chat)
    unless ingest_only?, do: Mode.set_mode(:night_batch)

    # the cut-off hour is platform-wide (spec 6.11); the nightly batch gives each desk its
    # share of the night (F-355)
    deadline =
      Keyword.get_lazy(opts, :deadline, fn -> calculate_deadline(Settings.platform_setting!()) end)

    Logger.info("Starting Night Batch ##{batch_run.id}. Deadline: #{inspect(deadline)}")

    # Start caffeinate process to prevent macOS sleep during nightly batch (12-6)
    caffeinate_port =
      if System.find_executable("caffeinate") do
        Port.open({:spawn_executable, System.find_executable("caffeinate")}, [
          :binary,
          args: ["-s"]
        ])
      else
        nil
      end

    cleanup = fn ->
      # Leave night_batch for whatever mode the clock calls for (daytime or standby)
      Mode.end_batch()
      if ingest_only?, do: rewarm_embedding(setting)
      if caffeinate_port, do: Port.close(caffeinate_port)
      Progress.unbind()
    end

    try do
      result = fun.(batch_run, deadline)
      cleanup.()
      result
    rescue
      e ->
        # the message and where it happened, shown on the dashboard (the server's log may be
        # out of reach of whoever looks at the failed run)
        error = Exception.format(:error, e, Enum.take(__STACKTRACE__, 8))
        Logger.error("Batch ##{batch_run.id} failed with error: #{error}")

        batch_run
        |> BatchRun.changeset(%{
          finished_at: DateTime.utc_now(),
          status: "failed",
          error: String.slice(error, 0, 4000)
        })
        |> Repo.update()

        cleanup.()
        {:error, e}
    catch
      :throw, :batch_stop_requested ->
        Logger.info("Batch ##{batch_run.id} stopped at the admin's request")

        {:ok, batch_run} =
          batch_run
          |> Repo.reload!()
          |> BatchRun.changeset(%{finished_at: DateTime.utc_now(), status: "stopped"})
          |> Repo.update()

        LLM.unload_model(setting.batch_model, setting: setting)
        cleanup.()
        {:ok, batch_run}
    end
  end

  # =========================================================================
  # Phase 1: Sync (Drive metadata & content sync)
  # =========================================================================

  defp run_phase_1_sync(batch_run, setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 1: Sync] starting...")

    Progress.start_phase("sync", 0)
    Progress.detail("Drive のファイル一覧を取得中")

    # Ensure all LLM models unloaded during pure sync
    LLM.unload_model(setting.batch_model, setting: setting)

    items_count =
      case SyncWorker.perform(%Oban.Job{args: %{"batch_run_id" => batch_run.id}}) do
        {:ok, %{total_drive_files: count}} -> count
        {:ok, _} -> 1
        _ -> 0
      end

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    stat = record_phase_stat(batch_run, "sync", start_time, finished_time, duration, items_count)
    {stat, batch_run}
  end

  # =========================================================================
  # Phase 2: Invalidate (Mark stale dependencies)
  # =========================================================================

  defp run_phase_2_invalidate(batch_run, _setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 2: Invalidate] starting...")
    Progress.start_phase("invalidate", 0)

    # Find modified documents where hash changed but old QAs are still active
    invalidated_count =
      Repo.one(
        from q in QAPair,
          where: q.status == "stale",
          select: count(q.id)
      )

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    batch_run =
      batch_run
      |> BatchRun.changeset(%{qa_invalidated: invalidated_count})
      |> Repo.update!()

    stat =
      record_phase_stat(
        batch_run,
        "invalidate",
        start_time,
        finished_time,
        duration,
        invalidated_count
      )

    {stat, batch_run}
  end

  # =========================================================================
  # Phase 3: Embed Chunks (Embed newly added / modified chunks)
  # =========================================================================

  defp run_phase_3_embed_chunks(batch_run, setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 3: Embed Chunks] starting...")

    # Ensure embed model is loaded, batch model unloaded
    LLM.unload_model(setting.batch_model, setting: setting)

    # Process all pending / updated documents that need chunking & embedding
    unindexed_docs =
      Repo.all(
        from d in AskDrive.Documents.Document,
          where: d.status in ["pending", "processing"]
      )

    Logger.info(
      "Batch ##{batch_run.id} - [Phase 3] #{length(unindexed_docs)} document(s) to index"
    )

    Progress.start_phase("embed_chunks", length(unindexed_docs))

    {items_count, chunk_total} =
      unindexed_docs
      |> Enum.with_index()
      |> Enum.reduce({0, 0}, fn {doc, index}, {ok, chunks} ->
        args = %{"document_id" => doc.id, "batch_run_id" => batch_run.id}
        Progress.item(index, doc.path || doc.name)

        case EmbedChunksWorker.perform(%Oban.Job{args: args}) do
          {:ok, {:indexed, %{new: n}}} -> {ok + 1, chunks + n}
          {:ok, _} -> {ok + 1, chunks}
          _ -> {ok, chunks}
        end
      end)

    Progress.done(length(unindexed_docs))

    Logger.info(
      "Batch ##{batch_run.id} - [Phase 3] indexed #{items_count}/#{length(unindexed_docs)} document(s), #{chunk_total} new chunk(s) embedded"
    )

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    # Unload embed model at phase boundary
    LLM.unload_model(setting.embed_model,
      setting: setting,
      provider: LLM.embedding_provider(setting)
    )

    stat =
      record_phase_stat(
        batch_run,
        "embed_chunks",
        start_time,
        finished_time,
        duration,
        items_count
      )

    {stat, batch_run}
  end

  # =========================================================================
  # Phase 4: Generate (QA, Summaries, Extractions)
  # =========================================================================

  defp run_phase_4_generate(batch_run, setting, deadline, force_all) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 4: Generate] starting...")

    # Embed model already unloaded. Now generation model will be loaded by Ollama on first request.
    # Collect candidate chunk IDs from unresolved Tier 2 / 3 question logs (Priority 1)
    unresolved_logs =
      Repo.all(
        from q in AskDrive.QA.QuestionLog,
          where: is_nil(q.resolved_at) and q.tier_reached in [2, 3]
      )

    unresolved_chunk_ids =
      unresolved_logs
      |> Enum.flat_map(fn log -> log.candidate_chunk_ids || [] end)
      |> Enum.uniq()

    chunks_query =
      if force_all do
        from(c in Chunk)
      else
        pending_generation_query()
      end

    all_pending = Repo.all(chunks_query)

    # Sort chunks by specification priority (11-1 & 11-2):
    # 1. Associated with unresolved question logs
    # 2. Has stale QA pairs
    # 3. New chunks (no QA pairs)
    # 4. High reference count
    # 5. Rest
    stale_chunk_ids =
      Repo.all(from q in QAPair, where: q.status == "stale", select: q.chunk_id) |> MapSet.new()

    unresolved_set = MapSet.new(unresolved_chunk_ids)

    pending_chunks =
      Enum.sort_by(all_pending, fn chunk ->
        # chunks that failed before go after every untried one (F-342), so a chunk the model
        # keeps tripping over doesn't eat the start of every night
        retry = min(chunk.qa_attempts || 0, 1)

        cond do
          MapSet.member?(unresolved_set, chunk.id) ->
            {retry, 0, -chunk.reference_count, chunk.id}

          MapSet.member?(stale_chunk_ids, chunk.id) ->
            {retry, 1, -chunk.reference_count, chunk.id}

          true ->
            {retry, 2, -chunk.reference_count, chunk.id}
        end
      end)

    total_chunks = length(pending_chunks)
    Logger.info("Batch ##{batch_run.id} - Found #{total_chunks} chunks queued for generation.")
    Progress.start_phase("generate", total_chunks)
    Process.put({__MODULE__, :doc_names}, document_names(pending_chunks))

    {processed_count, generated_qa_count, deadline_reached?} =
      process_generation_loop(
        pending_chunks,
        setting,
        deadline,
        0,
        0
      )

    # Optional: Generate document summaries if enabled
    if Map.get(setting, :summary_enabled, false) == true do
      docs_without_summary =
        Repo.all(
          from d in AskDrive.Documents.Document,
            left_join: s in AskDrive.Documents.DocSummary,
            on: s.document_id == d.id,
            where: d.status == "indexed" and is_nil(s.id)
        )

      Enum.each(docs_without_summary, fn doc ->
        # Get all chunk contents
        chunks =
          Repo.all(
            from c in Chunk,
              where: c.document_id == ^doc.id,
              order_by: [asc: c.position]
          )

        full_text = Enum.map_join(chunks, "\n\n", & &1.content)

        if full_text != "" do
          case Summary.generate(full_text, LLM.generation_model(setting), setting.batch_num_ctx) do
            {:ok, summary_text} ->
              %AskDrive.Documents.DocSummary{}
              |> AskDrive.Documents.DocSummary.changeset(%{
                document_id: doc.id,
                summary: summary_text,
                status: "active"
              })
              |> Repo.insert()

            _ ->
              :ok
          end
        end
      end)
    end

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    # Unload generation model immediately at phase boundary
    LLM.unload_model(setting.batch_model, setting: setting)

    batch_run =
      batch_run
      |> BatchRun.changeset(%{
        chunks_processed: processed_count,
        qa_generated: generated_qa_count,
        queue_remaining: max(0, total_chunks - processed_count)
      })
      |> Repo.update!()

    stat =
      record_phase_stat(
        batch_run,
        "generate",
        start_time,
        finished_time,
        duration,
        processed_count
      )

    {stat, batch_run, deadline_reached?}
  end

  defp process_generation_loop([], _setting, _deadline, processed, qa_count) do
    {processed, qa_count, false}
  end

  defp process_generation_loop([chunk | rest], setting, deadline, processed, qa_count) do
    # Check deadline
    now = DateTime.utc_now()

    if deadline && DateTime.compare(now, deadline) in [:gt, :eq] do
      Logger.warning("Batch generation deadline #{inspect(deadline)} reached. Stopping Phase 4.")
      {processed, qa_count, true}
    else
      # progress: the chunk being generated, and the counts so far in the history table
      Progress.item(processed, chunk_label(chunk), %{
        chunks_processed: processed,
        qa_generated: qa_count
      })

      outcome =
        try do
          generate_chunk(chunk, setting)
        rescue
          # one chunk the model (or the data) trips over must not fail the whole night's
          # batch; it is logged and the chunk stays without QA for the next run
          e ->
            Logger.error(
              "Batch: generation crashed on chunk #{chunk.id}: #{Exception.format(:error, e, __STACKTRACE__)}"
            )

            ItemLog.record(Progress.current_run_id(), %{
              phase: "generate",
              document_id: chunk.document_id,
              name: chunk_label(chunk),
              status: "failed",
              message: "QA 生成で例外: " <> String.slice(Exception.message(e), 0, 300)
            })

            {:error, {:exception, Exception.message(e)}}
        end

      new_qas = record_generation_outcome(chunk, outcome)

      process_generation_loop(
        rest,
        setting,
        deadline,
        processed + 1,
        qa_count + new_qas
      )
    end
  end

  @max_qa_attempts 3

  @doc """
  Chunks that still need QA (spec F-342): no QA yet or stale QA, and fewer than
  #{@max_qa_attempts} failed attempts. A re-run after a failure, stop or cut-off therefore
  continues where the last run left off: chunks with QA are not generated again.
  """
  def pending_generation_query do
    from c in Chunk,
      left_join: q in QAPair,
      on: q.chunk_id == c.id,
      where: (is_nil(q.id) or q.status == "stale") and c.qa_attempts < @max_qa_attempts,
      distinct: true
  end

  @doc "Chunks skipped after #{@max_qa_attempts} failed attempts, newest failure first."
  def given_up_chunks(limit \\ 50) do
    Repo.all(
      from c in Chunk,
        left_join: q in QAPair,
        on: q.chunk_id == c.id and q.status == "active",
        where: is_nil(q.id) and c.qa_attempts >= @max_qa_attempts,
        order_by: [desc: c.qa_attempted_at],
        limit: ^limit,
        preload: [:document]
    )
  end

  @doc "Puts every given-up chunk back in the queue (their attempt count starts over)."
  def retry_given_up_chunks do
    {count, _} =
      Repo.update_all(from(c in Chunk, where: c.qa_attempts >= @max_qa_attempts),
        set: [qa_attempts: 0, qa_error: nil]
      )

    count
  end

  @doc """
  What a re-run would still do (spec F-342): documents to index, chunks to generate,
  chunks given up, and generated questions still to embed.
  """
  def remaining do
    %{
      documents:
        Repo.one(
          from d in AskDrive.Documents.Document,
            where: d.status in ["pending", "processing"],
            select: count(d.id)
        ),
      chunks: Repo.one(from c in subquery(pending_generation_query()), select: count(c.id)),
      given_up:
        Repo.one(
          from c in Chunk,
            left_join: q in QAPair,
            on: q.chunk_id == c.id and q.status == "active",
            where: is_nil(q.id) and c.qa_attempts >= @max_qa_attempts,
            select: count(c.id)
        ),
      questions:
        Repo.one(
          from q in QAPair,
            where: is_nil(q.question_embedding) and q.status == "active",
            select: count(q.id)
        )
    }
  end

  # A failure that says something about the chunk (the model's output couldn't be used, it
  # crashed, it ran past the timeout) counts against it; one that says nothing about it
  # (Ollama down, generation not allowed in this mode, quota) doesn't, or one bad night would
  # give up on every chunk.
  defp record_generation_outcome(chunk, {:ok, count}) do
    if (chunk.qa_attempts || 0) > 0 or chunk.qa_error do
      Repo.update_all(from(c in Chunk, where: c.id == ^chunk.id),
        set: [qa_attempts: 0, qa_error: nil, qa_attempted_at: now_s()]
      )
    end

    count
  end

  defp record_generation_outcome(chunk, {:error, reason}) do
    if counts_against_chunk?(reason) do
      Repo.update_all(from(c in Chunk, where: c.id == ^chunk.id),
        inc: [qa_attempts: 1],
        set: [qa_error: describe_generation_error(reason), qa_attempted_at: now_s()]
      )
    end

    0
  end

  defp counts_against_chunk?(reason) when is_binary(reason), do: true
  defp counts_against_chunk?({:exception, _}), do: true
  defp counts_against_chunk?({:timeout, _}), do: true
  defp counts_against_chunk?({:invalid_response, _}), do: true
  defp counts_against_chunk?(_), do: false

  defp describe_generation_error(reason) when is_binary(reason), do: String.slice(reason, 0, 255)
  defp describe_generation_error({:exception, msg}), do: String.slice("例外: " <> msg, 0, 255)
  defp describe_generation_error({:timeout, _}), do: "時間切れ（応答がタイムアウトしました）"
  defp describe_generation_error(other), do: other |> inspect() |> String.slice(0, 255)

  defp now_s, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # QA (and, if enabled, structured fields) for one chunk: {:ok, QA saved} or {:error, reason}
  defp generate_chunk(chunk, setting) do
    # 1. Generate QA pairs
    result =
      case QA.generate_for_chunk(chunk, LLM.generation_model(setting), setting.batch_num_ctx) do
        {:ok, qa_list} ->
          saved =
            Enum.map(qa_list, fn item ->
              {:ok, qa_pair} =
                AskDrive.QA.create_qa_pair(%{
                  document_id: chunk.document_id,
                  chunk_id: chunk.id,
                  question: item.question,
                  answer: item.answer,
                  status: "active",
                  hallucination_flag: item.hallucination_flag,
                  generated_by: LLM.generation_model(setting),
                  generated_at: DateTime.utc_now(),
                  source_hash: chunk.content_hash
                })

              qa_pair
            end)

          {:ok, length(saved)}

        {:error, reason} ->
          Logger.error("Failed to generate QA for chunk #{chunk.id}: #{inspect(reason)}")
          {:error, reason}
      end

    # 2. Extract structured fields if enabled
    if Map.get(setting, :extraction_enabled, false) == true do
      case Extraction.extract(
             chunk.content,
             LLM.generation_model(setting),
             setting.batch_num_ctx
           ) do
        {:ok, items} when items != [] ->
          # Save extractions
          Enum.each(items, fn item ->
            AskDrive.Documents.create_extraction(%{
              document_id: chunk.document_id,
              chunk_id: chunk.id,
              key: item["key"] || "item",
              value: to_string(item["value"]),
              value_type: item["value_type"] || "text"
            })
          end)

        _ ->
          :ok
      end
    end

    result
  end

  # =========================================================================
  # Phase 5: Embed Questions (Vectorize newly generated hypothetical Qs)
  # =========================================================================

  defp run_phase_5_embed_questions(batch_run, setting) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 5: Embed Questions] starting...")

    # Embed model loaded for question vectors
    unembedded_qas =
      Repo.all(
        from q in QAPair,
          where: is_nil(q.question_embedding) and q.status == "active"
      )

    items_count = length(unembedded_qas)
    Logger.info("Batch ##{batch_run.id} - Found #{items_count} questions to embed.")
    Progress.start_phase("embed_questions", items_count)

    if items_count > 0 do
      qa_ids = Enum.map(unembedded_qas, & &1.id)
      # Batch in chunks of 50
      qa_ids
      |> Enum.chunk_every(50)
      |> Enum.reduce(0, fn chunk_ids, done ->
        EmbedQuestionsWorker.perform(%Oban.Job{args: %{"qa_pair_ids" => chunk_ids}})
        done = done + length(chunk_ids)
        Progress.done(done)
        done
      end)
    end

    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    # Unload embed model
    LLM.unload_model(setting.embed_model,
      setting: setting,
      provider: LLM.embedding_provider(setting)
    )

    stat =
      record_phase_stat(
        batch_run,
        "embed_questions",
        start_time,
        finished_time,
        duration,
        items_count
      )

    {stat, batch_run}
  end

  # =========================================================================
  # Phase 6: Verify & Finish
  # =========================================================================

  defp run_phase_6_verify(batch_run, _setting, deadline_reached?) do
    start_time = DateTime.utc_now()
    Logger.info("Batch ##{batch_run.id} - [Phase 6: Verify] starting...")
    Progress.start_phase("verify", 0)

    # Resolve question_log entries whose candidate chunks now have active QAs (11-3)
    unresolved_logs =
      Repo.all(
        from q in AskDrive.QA.QuestionLog,
          where: is_nil(q.resolved_at)
      )

    resolved_count =
      Enum.reduce(unresolved_logs, 0, fn log, acc ->
        candidate_ids = log.candidate_chunk_ids || []

        matching_qa =
          if candidate_ids != [] do
            Repo.one(
              from q in QAPair,
                where: q.chunk_id in ^candidate_ids and q.status == "active",
                order_by: [desc: q.id],
                limit: 1
            )
          else
            nil
          end

        if matching_qa do
          log
          |> AskDrive.QA.QuestionLog.changeset(%{
            resolved_at: DateTime.utc_now(),
            resolved_qa_id: matching_qa.id
          })
          |> Repo.update()

          acc + 1
        else
          acc
        end
      end)

    # Verify virtual table counts or consistency
    final_status = if deadline_reached?, do: "deadline_reached", else: "completed"
    finished_time = DateTime.utc_now()
    duration = DateTime.diff(finished_time, start_time)

    batch_run =
      batch_run
      |> BatchRun.changeset(%{
        finished_at: finished_time,
        status: final_status,
        questions_resolved: resolved_count
      })
      |> Repo.update!()

    stat =
      record_phase_stat(
        batch_run,
        "verify",
        start_time,
        finished_time,
        duration,
        resolved_count
      )

    # Perform WAL checkpoint, automated database backup, and temp cleanup after batch completion
    try do
      AskDrive.Backup.checkpoint_wal(:truncate)
      AskDrive.Backup.backup_all()
      AskDrive.Cleanup.clean_temp_files()
    rescue
      e ->
        Logger.warning(
          "Phase 6 maintenance task (backup/checkpoint/cleanup) encountered non-fatal error: #{Exception.message(e)}"
        )
    end

    Logger.info(
      "Batch ##{batch_run.id} finished with status: #{final_status}, questions resolved: #{resolved_count}"
    )

    {stat, batch_run}
  end

  # --- Helpers ---

  defp document_names(chunks) do
    ids = chunks |> Enum.map(& &1.document_id) |> Enum.uniq()

    Repo.all(
      from d in AskDrive.Documents.Document,
        where: d.id in ^ids,
        select: {d.id, fragment("coalesce(?, ?)", d.path, d.name)}
    )
    |> Map.new()
  end

  defp chunk_label(chunk) do
    name = Map.get(Process.get({__MODULE__, :doc_names}, %{}), chunk.document_id, "文書")
    if chunk.position, do: "#{name}（チャンク #{chunk.position + 1}）", else: name
  end

  # The next batch_deadline_hour:00 in local time (spec F-339; default 08:00). The automatic
  # run may start until batch_end_hour (07:00), and gets until the deadline to finish.
  # (It used to be batch_end_hour in UTC: "07:00" meant 16:00 JST.)
  def calculate_deadline(setting, now \\ AskDrive.Clock.local_now()) do
    end_hour = setting.batch_deadline_hour || 8
    today_deadline = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(end_hour, 0, 0))

    deadline =
      if NaiveDateTime.compare(now, today_deadline) == :lt,
        do: today_deadline,
        else: NaiveDateTime.add(today_deadline, 86_400)

    AskDrive.Clock.local_to_utc(deadline)
  end

  # Phase 3 unloads the embedding model at its boundary. After a full batch the switch back
  # to daytime re-warms it; an ingest-only run never left daytime, so do it here.
  defp rewarm_embedding(setting) do
    if Mode.current_mode() == :daytime do
      Task.start(fn -> LLM.prewarm_embedding(setting.embed_model, setting: setting) end)
    end
  end

  defp record_phase_stat(batch_run, phase_name, start_time, finished_time, duration, count) do
    %BatchPhaseStat{}
    |> BatchPhaseStat.changeset(%{
      batch_run_id: batch_run.id,
      phase_name: phase_name,
      started_at: start_time,
      finished_at: finished_time,
      duration_seconds: max(0, duration),
      items_count: count,
      status: "completed"
    })
    |> Repo.insert!()
  end
end
