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
    {count, _} =
      Repo.update_all(
        from(b in BatchRun, where: b.status == "running" and is_nil(b.stop_requested_at)),
        set: [stop_requested_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    if count > 0, do: :ok, else: {:error, :not_running}
  end

  @doc "Whether any app's batch is running (they share one local model; spec 6.11)."
  def running_anywhere? do
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
  """
  def run_batch(opts \\ []) do
    # The nightly cron and a manual run — in this app or another — could otherwise overlap
    # and fight over the one local model.
    if running_anywhere?() do
      Logger.warning("Batch requested while another is running; skipped")
      {:error, :already_running}
    else
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
  state: :running | :done | :due | :missed, run: run | nil, next_start: local}`.
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

  defp do_run_batch(opts) do
    force_all = Keyword.get(opts, :force, false)
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

    # progress reports from this process (and the workers it calls) go to this run (F-340)
    Progress.bind(batch_run.id)

    # Transition runtime mode into night_batch (a full batch only: ingest-only never loads the
    # generation model, and the daytime mode keeps the embedding model resident for chat)
    unless ingest_only?, do: Mode.set_mode(:night_batch)

    # the cut-off hour is platform-wide (spec 6.11)
    deadline = calculate_deadline(Settings.platform_setting!())
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

    try do
      # --- Phase 1: Sync ---
      {_p1_stat, batch_run} = run_phase_1_sync(batch_run, setting)

      # --- Phase 2: Invalidate ---
      {_p2_stat, batch_run} = run_phase_2_invalidate(batch_run, setting)

      # --- Phase 3: Embed Chunks ---
      {_p3_stat, batch_run} = run_phase_3_embed_chunks(batch_run, setting)

      {batch_run, deadline_reached?} =
        if ingest_only? do
          Logger.info("Batch ##{batch_run.id} - ingest only: skipping Phase 4 (Generate) and 5")
          {batch_run, false}
        else
          # --- Phase 4: Generate (Deadline-controlled) ---
          {_p4_stat, batch_run, deadline_reached?} =
            run_phase_4_generate(batch_run, setting, deadline, force_all)

          # --- Phase 5: Embed Questions ---
          {_p5_stat, batch_run} = run_phase_5_embed_questions(batch_run, setting)
          {batch_run, deadline_reached?}
        end

      # --- Phase 6: Verify & Finish ---
      {_p6_stat, batch_run} = run_phase_6_verify(batch_run, setting, deadline_reached?)

      # Leave night_batch for whatever mode the clock calls for (daytime or standby)
      Mode.end_batch()
      if ingest_only?, do: rewarm_embedding(setting)

      if caffeinate_port, do: Port.close(caffeinate_port)
      Progress.unbind()

      {:ok, batch_run}
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

        Mode.end_batch()
        if ingest_only?, do: rewarm_embedding(setting)
        if caffeinate_port, do: Port.close(caffeinate_port)
        Progress.unbind()
        {:error, e}
    catch
      :throw, :batch_stop_requested ->
        Logger.info("Batch ##{batch_run.id} stopped at the admin's request")
        Progress.unbind()

        {:ok, batch_run} =
          batch_run
          |> Repo.reload!()
          |> BatchRun.changeset(%{finished_at: DateTime.utc_now(), status: "stopped"})
          |> Repo.update()

        LLM.unload_model(setting.batch_model, setting: setting)
        Mode.end_batch()
        if ingest_only?, do: rewarm_embedding(setting)
        if caffeinate_port, do: Port.close(caffeinate_port)
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
        # Find chunks without QA pairs or with stale QA pairs
        from c in Chunk,
          left_join: q in QAPair,
          on: q.chunk_id == c.id,
          where: is_nil(q.id) or q.status == "stale",
          distinct: true
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
        cond do
          MapSet.member?(unresolved_set, chunk.id) -> {0, -chunk.reference_count, chunk.id}
          MapSet.member?(stale_chunk_ids, chunk.id) -> {1, -chunk.reference_count, chunk.id}
          true -> {2, -chunk.reference_count, chunk.id}
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

      new_qas =
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

            0
        end

      process_generation_loop(
        rest,
        setting,
        deadline,
        processed + 1,
        qa_count + new_qas
      )
    end
  end

  # QA (and, if enabled, structured fields) for one chunk; returns the number of QA saved
  defp generate_chunk(chunk, setting) do
    # 1. Generate QA pairs
    new_qas =
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

          length(saved)

        {:error, reason} ->
          Logger.error("Failed to generate QA for chunk #{chunk.id}: #{inspect(reason)}")
          0
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

    new_qas
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
