defmodule AskDrive.Batch.SyncWorkerTest do
  use AskDrive.DataCase
  alias AskDrive.Batch.SyncWorker

  test "returns error if not connected" do
    assert {:error, :not_connected} = SyncWorker.perform(%Oban.Job{args: %{}})
  end
end
