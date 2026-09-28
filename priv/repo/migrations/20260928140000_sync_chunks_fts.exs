defmodule AskDrive.Repo.Migrations.SyncChunksFts do
  use Ecto.Migration

  # chunks_fts is an external-content FTS5 table (content=chunks), which SQLite never fills
  # on its own: without these triggers the index stayed empty, every MATCH returned nothing,
  # and keyword search silently degraded to a verbatim LIKE. The triggers follow the SQLite
  # FTS5 documentation for external content tables; the rebuild indexes existing chunks.
  def up do
    execute """
    CREATE TRIGGER IF NOT EXISTS chunks_fts_ai AFTER INSERT ON chunks BEGIN
      INSERT INTO chunks_fts(rowid, content, heading) VALUES (new.id, new.content, new.heading);
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS chunks_fts_ad AFTER DELETE ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, content, heading)
        VALUES ('delete', old.id, old.content, old.heading);
    END;
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS chunks_fts_au AFTER UPDATE ON chunks BEGIN
      INSERT INTO chunks_fts(chunks_fts, rowid, content, heading)
        VALUES ('delete', old.id, old.content, old.heading);
      INSERT INTO chunks_fts(rowid, content, heading) VALUES (new.id, new.content, new.heading);
    END;
    """

    execute "INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild');"
  end

  def down do
    execute "DROP TRIGGER IF EXISTS chunks_fts_ai;"
    execute "DROP TRIGGER IF EXISTS chunks_fts_ad;"
    execute "DROP TRIGGER IF EXISTS chunks_fts_au;"
  end
end
