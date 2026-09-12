defmodule SymphonyElixir.LifecycleCoordinatorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LifecycleCoordinator, LifecycleHistory}

  defmodule FakeGitHubClient do
    def fetch_issue(_issue_id), do: {:ok, Agent.get(state(), & &1.issue)}
    def fetch_issue_comments(_issue_id), do: {:ok, Agent.get(state(), & &1.comments)}

    def append_issue_comment(_issue_id, body) do
      Agent.get_and_update(state(), fn current ->
        comment = %{"body" => body}
        {{:ok, comment}, %{current | comments: current.comments ++ [comment], trace: current.trace ++ [{:append, body}]}}
      end)
    end

    def add_issue_label(_issue_id, label) do
      Agent.get_and_update(state(), fn current ->
        labels = Enum.uniq(current.issue.labels ++ [String.downcase(label)])
        issue = %{current.issue | labels: labels}
        {{:ok, labels}, %{current | issue: issue, trace: current.trace ++ [{:add, label}]}}
      end)
    end

    def remove_issue_label(_issue_id, label) do
      Agent.get_and_update(state(), fn current ->
        labels = Enum.reject(current.issue.labels, &(String.downcase(&1) == String.downcase(label)))
        issue = %{current.issue | labels: labels}
        {{:ok, labels}, %{current | issue: issue, trace: current.trace ++ [{:remove, label}]}}
      end)
    end

    defp state, do: Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state)
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{issue: github_issue(), comments: [], trace: []} end)
    previous_client = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :lifecycle_fake_github_state, agent)
    Application.delete_env(:symphony_elixir, :github_client_module)
    File.write!(InstanceConfig.instance_config_file_path(), github_config())
    assert :ok = InstanceConfigStore.force_reload()
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_client)
      end

      Application.delete_env(:symphony_elixir, :lifecycle_fake_github_state)
      Agent.stop(agent)
    end)

    :ok
  end

  test "initializes, commits, and idempotently replays a PM transition" do
    issue = github_issue()
    assert {:ok, %{history: %{lifecycle_id: lifecycle_id}}} = LifecycleCoordinator.prepare_dispatch(issue)

    result = role_result("PM", "plan", "Plan accepted intent")
    assert {:ok, %{idempotent?: false, event: event, issue: projected}} =
             LifecycleCoordinator.commit_role_result(issue, :pm, result)

    assert event["kind"] == "transition"
    assert event["to_role"] == "PLANNER"
    assert event["lifecycle_id"] == lifecycle_id
    assert projected.labels == ["symphony:auto", "human-label", "symphony:role:planner"]

    assert {:ok, %{idempotent?: true}} =
             LifecycleCoordinator.commit_role_result(issue, :pm, result)

    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert Enum.count(state.comments, &String.contains?(&1["body"], "symphony.lifecycle/v1")) == 2

    transition_append_index =
      Enum.find_index(state.trace, fn
        {:append, body} -> String.contains?(body, "\"kind\":\"transition\"")
        _ -> false
      end)

    first_projection_mutation_index =
      state.trace
      |> Enum.with_index()
      |> Enum.find_value(fn
        {{:remove, "symphony:role:pm"}, index} when index > transition_append_index -> index
        _ -> nil
      end)

    assert transition_append_index < first_projection_mutation_index
  end

  test "does not dispatch an opted-out issue" do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{state | issue: %{state.issue | labels: ["symphony:role:pm"]}}
    end)

    assert {:error, :symphony_auto_required} = LifecycleCoordinator.prepare_dispatch(github_issue())
  end

  test "a destination label without its durable event is blocked" do
    Agent.update(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), fn state ->
      %{state | issue: %{state.issue | labels: ["symphony:auto", "symphony:role:planner"]}, comments: [
        %{"body" => LifecycleHistory.render(LifecycleHistory.start_event("life-1"), "started")}
      ]}
    end)

    assert {:skip, {:blocked_lifecycle, _reason}} = LifecycleCoordinator.prepare_dispatch(github_issue())
    state = Agent.get(Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state), & &1)
    assert "symphony:state:blocked" in state.issue.labels
    refute "symphony:auto" in state.issue.labels
  end

  test "blocks PM continuity without consuming lifecycle state" do
    issue = github_issue()

    assert {:ok, projected} =
             LifecycleCoordinator.block_pm_continuity(issue, :required_thread_unavailable)

    assert projected.state == "open"
    assert projected.labels == ["symphony:role:pm", "human-label", "symphony:state:blocked"]

    state =
      Agent.get(
        Application.fetch_env!(:symphony_elixir, :lifecycle_fake_github_state),
        & &1
      )

    assert Enum.any?(state.comments, &String.contains?(&1["body"], "PM thread continuity blocked"))

    append_index =
      Enum.find_index(state.trace, fn
        {:append, body} -> String.contains?(body, "PM thread continuity blocked")
        _ -> false
      end)

    remove_auto_index = Enum.find_index(state.trace, &(&1 == {:remove, "symphony:auto"}))
    assert append_index < remove_auto_index
  end

  defp github_issue do
    %Issue{
      id: "42",
      identifier: "GH-42",
      title: "Lifecycle test",
      description: "Test issue",
      state: "open",
      url: "https://github.test/octo/repo/issues/42",
      labels: ["symphony:auto", "symphony:role:pm", "human-label"]
    }
  end

  defp github_config do
    """
    tracker:
      kind: github
      provider:
        repo: "octo/repo"
        token: "test-token"
      active_states: ["open"]
      terminal_states: ["closed"]
    polling:
      interval_ms: 30000
    workspace:
      root: "#{Path.join(System.tmp_dir!(), "symphony-lifecycle-test-workspaces")}"
    """
  end

  defp role_result(role, outcome, summary) do
    %{
      "schema" => "symphony.role-result/v1",
      "role" => role,
      "outcome" => outcome,
      "summary" => summary,
      "evidence" => ["host test evidence"],
      "findings" => []
    }
  end
end
