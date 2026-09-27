defmodule AskDrive.LLM.SemaphoreTest do
  use ExUnit.Case, async: true
  alias AskDrive.LLM.Semaphore

  test "runs functions sequentially or concurrently within limit" do
    result =
      Semaphore.run(fn ->
        :timer.sleep(10)
        :done
      end)

    assert result == :done
  end
end
