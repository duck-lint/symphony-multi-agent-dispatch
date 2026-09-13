defmodule SymphonyElixir.AgentRunnerPMThreadTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.PMThreadState

  setup do
    state_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-pm-state-#{System.unique_integer([:positive])}"
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

  test "first PM persists its new thread before starting the turn" do
    test_root = test_root("first")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    issue = issue("issue-pm-first", "MT-PM-FIRST")

    try do
      File.mkdir_p!(workspace_root)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:ok, state_path} = PMThreadState.path_for_test(issue.id)
      write_pm_fixture!(codex_binary, state_path, :fresh, "thread-pm-first")

      assert :ok =
               AgentRunner.run(issue, self(),
                 role: :pm,
                 lifecycle_id: "life-1",
                 pm_phase: :initial
               )

      assert_receive {:role_execution_completed, "issue-pm-first", %{role: :pm, thread_id: "thread-pm-first"}}

      assert {:ok,
              %{
                "lifecycle_id" => "life-1",
                "thread_id" => "thread-pm-first",
                "thread_path" => "/tmp/thread-pm-first.json"
              }} =
               PMThreadState.load(issue.id)
    after
      File.rm_rf(test_root)
    end
  end

  test "returning PM resumes the persisted thread without creating a replacement" do
    test_root = test_root("returning")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    issue = issue("issue-pm-returning", "MT-PM-RETURNING")

    try do
      File.mkdir_p!(workspace_root)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert :ok = PMThreadState.put(issue.id, "life-1", "thread-pm-existing")
      trace_path = Path.join(test_root, "codex.trace")
      write_pm_fixture!(codex_binary, trace_path, :reuse, "thread-pm-existing")

      assert :ok =
               AgentRunner.run(issue, self(),
                 role: :pm,
                 lifecycle_id: "life-1",
                 pm_phase: :returning
               )

      assert_receive {:role_execution_completed, "issue-pm-returning", %{role: :pm, thread_id: "thread-pm-existing"}}

      trace = File.read!(trace_path)
      refute trace =~ "\"method\":\"thread/start\""
      assert_request_methods(trace, ["initialize", "initialized", "thread/resume", "turn/start"])

      resume_request =
        trace
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&(&1["method"] == "thread/resume"))

      assert resume_request["params"]["threadId"] == "thread-pm-existing"
      assert resume_request["params"]["sandbox"] == "read-only"
      assert is_map(resume_request["params"]["approvalPolicy"])
    after
      File.rm_rf(test_root)
    end
  end

  test "unavailable returning PM thread is surfaced as a continuity failure" do
    test_root = test_root("returning-unavailable")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    issue = issue("issue-pm-unavailable", "MT-PM-UNAVAILABLE")

    try do
      File.mkdir_p!(workspace_root)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert :ok = PMThreadState.put(issue.id, "life-1", "thread-pm-missing")
      trace_path = Path.join(test_root, "codex.trace")
      write_pm_fixture!(codex_binary, trace_path, :reuse_failure, "thread-pm-missing")

      assert_raise RuntimeError, ~r/PM thread continuity failed/, fn ->
        AgentRunner.run(issue, self(),
          role: :pm,
          lifecycle_id: "life-1",
          pm_phase: :returning
        )
      end

      assert_receive {:role_execution_failed, "issue-pm-unavailable", failure}
      assert failure.kind == :pm_continuity
      assert failure.reason == {:required_thread_unavailable, {:response_error, %{"code" => -32_600, "message" => "thread not found"}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "specialists remain fresh even when PM state is unusable" do
    test_root = test_root("specialist")
    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    issue = issue("issue-specialist", "MT-SPECIALIST")

    try do
      File.mkdir_p!(workspace_root)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      assert {:ok, state_path} = PMThreadState.path_for_test(issue.id)
      File.mkdir_p!(Path.dirname(state_path))
      File.write!(state_path, "not-json")
      write_specialist_fixture!(codex_binary)

      assert :ok = AgentRunner.run(issue, self(), role: :planner)
      assert_receive {:role_execution_completed, "issue-specialist", %{role: :planner, thread_id: "thread-fresh"}}
    after
      File.rm_rf(test_root)
    end
  end

  defp write_pm_fixture!(path, state_or_trace_path, mode, thread_id) do
    {trace_path, state_path} =
      case mode do
        :fresh ->
          {Path.join(Path.dirname(path), "codex.trace"), state_or_trace_path}

        mode when mode in [:reuse, :reuse_failure] ->
          {state_or_trace_path, nil}
      end

    trace_path = String.replace(trace_path, "\\", "/")
    state_path = if state_path, do: String.replace(state_path, "\\", "/")
    result = role_result("PM", "plan", "PM handoff")

    result_message =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "agentMessage", "text" => result}}
      })

    turn_case =
      case mode do
        :fresh ->
          """
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"#{thread_id}","path":"/tmp/thread-pm-first.json"}}}' ;;
          4)
            test -f "#{state_path}" || exit 1
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-pm"}}}'
            printf '%s\\n' '#{result_message}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          """

        :reuse ->
          """
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"#{thread_id}"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-pm"}}}'
            printf '%s\\n' '#{result_message}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          """

        :reuse_failure ->
          """
          3)
            printf '%s\\n' '{"id":2,"error":{"code":-32600,"message":"thread not found"}}'
            exit 0
            ;;
          """
      end

    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf '%s\\n' "$line" >> "#{trace_path}"
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        #{turn_case}
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_specialist_fixture!(path) do
    result = role_result("PLANNER", "plan_ready", "planner handoff")

    result_message =
      Jason.encode!(%{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "agentMessage", "text" => result}}
      })

    File.write!(path, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\\n' '{"id":1,"result":{}}' ;;
        2) ;;
        3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-fresh"}}}' ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-fresh"}}}'
          printf '%s\\n' '#{result_message}'
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *) exit 0 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp role_result(role, outcome, summary) do
    Jason.encode!(%{
      "schema" => "symphony.role-result/v1",
      "role" => role,
      "outcome" => outcome,
      "summary" => summary,
      "evidence" => [],
      "findings" => []
    })
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "PM continuity test",
      description: "Exercise host-owned PM thread continuity",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: ["symphony:role:pm"]
    }
  end

  defp assert_request_methods(trace, expected_methods) do
    methods =
      trace
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map(&Map.get(&1, "method"))

    assert methods == expected_methods
  end

  defp test_root(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-pm-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end
end
