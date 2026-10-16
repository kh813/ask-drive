defmodule AskDrive.Repo.Migrations.NightlyWindowFromMidnight do
  use Ecto.Migration

  # The nightly batch now starts at 00:00 local (spec F-330). Move installations still on the
  # old 21:00 default; a start hour someone chose deliberately is left alone.
  def up do
    execute "UPDATE settings SET batch_start_hour = 0 WHERE batch_start_hour = 21"
  end

  def down do
    execute "UPDATE settings SET batch_start_hour = 21 WHERE batch_start_hour = 0"
  end
end
