defmodule SymphonyElixir.PMThreadStateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PMThreadState

  setup do
    state_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-pm-thread-state-#{System.unique_integer([:positive])}"
      )

    previous_root = Application.get_env(:symphony_elixir, :pm_thread_state_root)
    Application.put_env(:symphony_elixir, :pm_thread_state_root, state_root)

    on_exit(fn ->
      if is_nil(previous_root) do
        Application.delete_env(:symphony_elixir, :pm_thread_state_root)
      else
        Application.put_env(:symphony_elixir, :pm_thread_state_root, previous_root)
      end

      File.rm_rf(state_root)
    end)

    :ok
  end

  test "persists only the lifecycle-bound PM reconnect record outside the workspace" do
    assert :ok = PMThreadState.put("42", "life-1", "thread-1")
    assert {:ok, record} = PMThreadState.load("42")

    assert record == %{
             "schema" => "symphony.pm-thread/v1",
             "lifecycle_id" => "life-1",
             "thread_id" => "thread-1"
           }

    assert {:ok, path} = PMThreadState.path_for_test("42")
    refute String.contains?(path, "symphony_workspaces")
  end

  test "resolves matching state and treats stale state according to PM phase" do
    assert {:new, :missing} = PMThreadState.resolve("42", "life-1", :initial)
    assert {:error, :pm_thread_state_missing} = PMThreadState.resolve("42", "life-1", :returning)

    assert :ok = PMThreadState.put("42", "old-life", "thread-old")
    assert {:new, {:stale_lifecycle, "old-life"}} = PMThreadState.resolve("42", "new-life", :initial)

    assert {:error, {:pm_thread_lifecycle_mismatch, "old-life", "new-life"}} =
             PMThreadState.resolve("42", "new-life", :returning)

    assert :ok = PMThreadState.put("42", "new-life", "thread-new")
    assert {:resume, "thread-new", nil} = PMThreadState.resolve("42", "new-life", :returning)
  end

  test "persists the Codex rollout path when the app-server provides one" do
    assert :ok = PMThreadState.put("42", "life-1", "thread-1", thread_path: "/tmp/rollout.json")
    assert {:ok, record} = PMThreadState.load("42")
    assert record["thread_path"] == "/tmp/rollout.json"
  end

  test "malformed state is replaceable only for a genuinely initial PM" do
    assert {:ok, path} = PMThreadState.path_for_test("42")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"schema":"symphony.pm-thread/v1","lifecycle_id":"life-1"}))

    assert {:new, {:replaceable_stale_state, _reason}} =
             PMThreadState.resolve("42", "life-1", :initial)

    assert {:error, {:pm_thread_state_unusable, {:malformed_pm_thread_state, ^path, _reason}}} =
             PMThreadState.resolve("42", "life-1", :returning)
  end

  test "rejects malformed records and unsafe identifiers" do
    assert {:error, {:malformed_pm_thread_state, _path, {:unknown_fields, ["prompt"]}}} =
             put_record_for_test(%{
               "schema" => PMThreadState.schema(),
               "lifecycle_id" => "life-1",
               "thread_id" => "thread-1",
               "prompt" => "must not be persisted"
             })

    assert {:error, :blank_or_unsafe_identifier} = PMThreadState.put("42", "life\n1", "thread-1")
    assert {:error, :blank_or_unsafe_identifier} = PMThreadState.put("42", "life-1", " ")
  end

  defp put_record_for_test(record) do
    assert {:ok, path} = PMThreadState.path_for_test("42")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(record))
    PMThreadState.load("42")
  end
end
