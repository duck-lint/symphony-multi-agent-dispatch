defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), poll_interval_ms: "invalid")

    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), max_retry_backoff_ms: 0)
    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "agent.max_retry_backoff_ms"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), max_retry_backoff_ms: 5)
    assert Config.settings!().agent.max_retry_backoff_ms == 5

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_api_token: "   ",
      tracker_project_slug: "project"
    )

    assert {:error, :missing_linear_api_token} = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: ""
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), codex_command: "   ")
    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_instance_config_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "current instance_config.yml file is valid and complete" do
    original_instance_config_path = InstanceConfig.instance_config_file_path()

    on_exit(fn -> InstanceConfig.set_instance_config_file_path(original_instance_config_path) end)

    InstanceConfig.clear_instance_config_file_path()

    assert {:ok, %{config: config}} = InstanceConfig.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "github"
    assert get_in(tracker, ["provider", "repo"]) == "duck-lint/symphony-multi-agent-dispatch"
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "instance_config file path defaults to .symphony/instance_config.yml when app env is unset" do
    original_instance_config_path = InstanceConfig.instance_config_file_path()

    on_exit(fn ->
      InstanceConfig.set_instance_config_file_path(original_instance_config_path)
    end)

    InstanceConfig.clear_instance_config_file_path()

    assert InstanceConfig.instance_config_file_path() ==
             Path.join([File.cwd!(), ".symphony", "instance_config.yml"])
  end

  test "instance_config file path resolves from app env when set" do
    app_instance_config_path = "/tmp/app/instance_config.yml"

    on_exit(fn ->
      InstanceConfig.clear_instance_config_file_path()
    end)

    InstanceConfig.set_instance_config_file_path(app_instance_config_path)

    assert InstanceConfig.instance_config_file_path() == app_instance_config_path
  end

  test "instance_config load accepts plain YAML maps without a prompt body" do
    instance_config_path =
      Path.join(Path.dirname(InstanceConfig.instance_config_file_path()), "PLAIN_instance_config.yml")

    File.write!(instance_config_path, "tracker:\n  kind: memory\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "memory"}}}} =
             InstanceConfig.load(instance_config_path)
  end

  test "instance_config load rejects YAML roots that are not maps" do
    instance_config_path =
      Path.join(Path.dirname(InstanceConfig.instance_config_file_path()), "INVALID_ROOT_instance_config.yml")

    File.write!(instance_config_path, "- not-a-map\n")

    assert {:error, :instance_config_not_a_map} = InstanceConfig.load(instance_config_path)
  end

  test "instance_config load reports malformed YAML" do
    instance_config_path =
      Path.join(Path.dirname(InstanceConfig.instance_config_file_path()), "MALFORMED_instance_config.yml")

    File.write!(instance_config_path, "tracker: [\n")

    assert {:error, {:instance_config_parse_error, _reason}} = InstanceConfig.load(instance_config_path)
  end

  test "SymphonyElixir.start_link starts the agent runtime" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        case Supervisor.restart_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(runtime_pid) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == pid
    assert is_pid(Process.whereis(SymphonyElixir.TaskSupervisor))
    assert is_pid(Process.whereis(SymphonyElixir.Orchestrator))

    GenServer.stop(pid)
  end

  test "orchestrator fails startup when semantic preflight fails" do
    issue_suffix = System.unique_integer([:positive])
    orchestrator_name = Module.concat(__MODULE__, "InvalidOrchestrator#{issue_suffix}")
    instance_config_path = InstanceConfig.instance_config_file_path()

    on_exit(fn ->
      if pid = Process.whereis(orchestrator_name) do
        GenServer.stop(pid)
      end

      write_instance_config_file!(instance_config_path, tracker_kind: "memory")

      if is_nil(Process.whereis(InstanceConfigStore)) do
        assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, InstanceConfigStore)
      end

      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        assert {:ok, _pid} =
                 Supervisor.restart_child(
                   SymphonyElixir.Supervisor,
                   SymphonyElixir.AgentRuntimeSupervisor
                 )
      end
    end)

    assert :ok =
             Supervisor.terminate_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             )

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, InstanceConfigStore)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, :missing_linear_project_slug} =
             Orchestrator.start_link(name: orchestrator_name)

    Process.flag(:trap_exit, previous_trap_exit)

    refute Process.whereis(orchestrator_name)
  end

  test "runtime restart keeps last good settings after an invalid reload" do
    issue_suffix = System.unique_integer([:positive])
    runtime_supervisor_name = Module.concat(__MODULE__, "ReloadRuntime#{issue_suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "ReloadTaskSupervisor#{issue_suffix}")
    orchestrator_name = Module.concat(__MODULE__, "ReloadOrchestrator#{issue_suffix}")

    on_exit(fn ->
      if pid = Process.whereis(runtime_supervisor_name) do
        GenServer.stop(pid)
      end
    end)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_kind: "memory")

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_supervisor_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_pid)
    original_orchestrator_pid = Process.whereis(orchestrator_name)

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()
    assert Config.settings!().tracker.kind == "memory"

    Process.exit(original_orchestrator_pid, :kill)

    restarted_orchestrator_pid =
      eventually_value(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != original_orchestrator_pid ->
            case Orchestrator.snapshot(orchestrator_name, 100) do
              %{} -> pid
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    assert is_pid(restarted_orchestrator_pid)
    assert Process.whereis(orchestrator_name) == restarted_orchestrator_pid
    assert Process.alive?(runtime_pid)
  end

  test "restarting the orchestrator does not overlap redispatched work" do
    issue_suffix = System.unique_integer([:positive])

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-restart-#{issue_suffix}"
      )

    hook_marker = Path.join(test_root, "before-run-started")
    hook_fifo = Path.join(test_root, "before-run-blocker")
    runtime_supervisor_name = Module.concat(__MODULE__, "AgentRuntimeSupervisor#{issue_suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "TaskSupervisor#{issue_suffix}")
    orchestrator_name = Module.concat(__MODULE__, "RestartOrchestrator#{issue_suffix}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    issue = %Issue{
      id: "issue-restart-#{issue_suffix}",
      identifier: "MT-#{issue_suffix}",
      title: "Restart an in-flight worker",
      description: "Keep one worker active while the orchestrator restarts",
      state: "In Progress",
      url: "https://example.org/issues/MT-#{issue_suffix}",
      labels: ["symphony:role:planner"],
      dispatchable: true
    }

    on_exit(fn ->
      if pid = Process.whereis(runtime_supervisor_name) do
        GenServer.stop(pid)
      end

      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restart_default_runtime!()
      File.rm_rf(test_root)
    end)

    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      poll_interval_ms: 10,
      hook_before_run: "mkfifo \"#{hook_fifo}\"; : > \"#{hook_marker}\"; read _ < \"#{hook_fifo}\"",
      hook_timeout_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, runtime_supervisor_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_supervisor_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_supervisor_pid)

    orchestrator_pid = Process.whereis(orchestrator_name)
    task_supervisor_pid = Process.whereis(task_supervisor_name)

    assert is_pid(orchestrator_pid)
    assert is_pid(task_supervisor_pid)

    first_worker_pid =
      eventually_value(fn ->
        case Task.Supervisor.children(task_supervisor_name) do
          [pid] -> pid
          _ -> nil
        end
      end)

    assert is_pid(first_worker_pid)
    assert Process.alive?(first_worker_pid)
    assert eventually_value(fn -> if File.exists?(hook_marker), do: true end)

    monitor_ref = Process.monitor(orchestrator_pid)
    Process.exit(orchestrator_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^orchestrator_pid, :killed}, 1_000

    restarted_pid =
      eventually_value(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != orchestrator_pid -> pid
          _ -> nil
        end
      end)

    restarted_task_supervisor_pid =
      eventually_value(fn ->
        case Process.whereis(task_supervisor_name) do
          pid when is_pid(pid) and pid != task_supervisor_pid -> pid
          _ -> nil
        end
      end)

    assert is_pid(restarted_pid)
    assert is_pid(restarted_task_supervisor_pid)
    assert is_map(GenServer.call(restarted_pid, :snapshot))
    refute Process.alive?(first_worker_pid)

    second_worker_pid =
      eventually_value(fn ->
        children = Task.Supervisor.children(task_supervisor_name)
        assert length(children) <= 1

        case children do
          [pid] when pid != first_worker_pid -> pid
          _ -> nil
        end
      end)

    assert is_pid(second_worker_pid)
    assert Process.alive?(second_worker_pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent before cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)
    worker_alive_marker = Path.join(test_root, "worker-alive")
    cleanup_marker = Path.join(test_root, "cleanup-order")

    try do
      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_before_remove: "if [ -f \"#{worker_alive_marker}\" ]; then printf alive > \"#{cleanup_marker}\"; else printf stopped > \"#{cleanup_marker}\"; fi"
      )

      File.mkdir_p!(workspace)
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      {:ok, agent_pid} =
        Task.Supervisor.start_child(task_supervisor, fn ->
          Process.flag(:trap_exit, true)
          File.write!(worker_alive_marker, "alive")

          try do
            receive do
              {:EXIT, _from, :shutdown} -> :ok
            end
          after
            File.rm(worker_alive_marker)
          end
        end)

      assert eventually_value(fn -> if File.exists?(worker_alive_marker), do: true end)

      state = %Orchestrator.State{
        task_supervisor: task_supervisor,
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.read!(cleanup_marker) == "stopped"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal cleanup uses the workspace recorded for the running issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-recorded-workspace-#{System.unique_integer([:positive])}"
      )

    old_root = Path.join(test_root, "old-root")
    new_root = Path.join(test_root, "new-root")
    issue_id = "issue-recorded-workspace"
    issue_identifier = "MT-557"
    old_workspace = Path.join(old_root, issue_identifier)
    new_workspace = Path.join(new_root, issue_identifier)

    try do
      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: old_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(old_workspace)
      File.mkdir_p!(new_workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            workspace_path: old_workspace,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      write_instance_config_file!(InstanceConfig.instance_config_file_path(), workspace_root: new_root)

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      _updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute File.exists?(old_workspace)
      assert File.exists?(new_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: [],
      dispatchable: true
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            dispatchable: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      dispatchable: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "retry releases its claim when dispatch revalidation no longer finds the issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-retry-refresh-#{System.unique_integer([:positive])}"
      )

    issue_id = "retry-refreshed-issue"

    try do
      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        hook_before_run: "exit 1"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      state = %Orchestrator.State{
        task_supervisor: task_supervisor,
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "MT-566",
        title: "Retry refreshed issue",
        state: "In Progress",
        dispatchable: true,
        labels: []
      }

      updated_state =
        Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
          identifier: issue.identifier,
          error: "agent exited"
        })

      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "normal worker exit without a retained role result uses the stock retry path" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert %{attempt: 1} = state.retry_attempts[issue_id]
    refute Map.has_key?(state.blocked, issue_id)
    assert MapSet.member?(state.claimed, issue_id)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_instance_config_file!(InstanceConfig.instance_config_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restart_default_runtime! do
    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      :ok =
        Supervisor.terminate_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
    end

    case Supervisor.restart_child(
           SymphonyElixir.Supervisor,
           SymphonyElixir.AgentRuntimeSupervisor
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp eventually_value(fun, attempts \\ 100)

  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders the host-selected role profile and issue context" do
    issue = %Issue{
      identifier: "MT-777",
      title: "Keep prompt ownership separate",
      description: "The instance config must not supply prompt prose.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, :reviewer, %{handoff: "Review the accepted plan."})

    assert prompt =~ "You are executing the SYMPHONY role REVIEWER."
    assert prompt =~ "Review the accepted plan."
    assert prompt =~ "judge whether a proposed plan satisfies the verification contract"
    assert prompt =~ "symphony.role-result/v1"
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Keep prompt ownership separate"
    assert prompt =~ "Body:"
    assert prompt =~ "The instance config must not supply prompt prose."
  end

  test "role prompt handles missing issue body" do
    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, :planner)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "structured lifecycle handoffs reach every role without inspection abbreviations" do
    issue = %Issue{
      identifier: "GH-8",
      title: "Preserve the complete lifecycle handoff",
      description: "The selected lifecycle evidence must reach the next role.",
      state: "In Progress",
      url: "https://example.org/issues/GH-8",
      labels: []
    }

    lifecycle_id = "3bLP9a-KKimOeer5JE9Rng"

    current_plan =
      "Corrective plan: retain the accepted evidence, update the bounded serializer, and verify the exact prompt at the Codex boundary."

    handoff = %{
      lifecycle_id: lifecycle_id,
      current_role: :reviewer,
      round: 2,
      planning_attempt: 2,
      pm_phase: :initial,
      completed_working_round?: false,
      preceding_adversary_findings: [],
      prerequisite_context: %{required?: false, outstanding_evidence_frontier: []},
      reconciliation: nil,
      revision_reconciliation: nil,
      accepted_events: [
        %{
          "lifecycle_id" => lifecycle_id,
          "transition_id" => "#{lifecycle_id}:r2:p1:PLANNER:plan_ready",
          "role" => "PLANNER",
          "from_role" => "PLANNER",
          "outcome" => "plan_ready",
          "to_role" => "REVIEWER",
          "round" => 2,
          "planning_attempt" => 1,
          "summary" => "Initial plan with substantial verification detail.",
          "evidence" => ["Earlier planning evidence remains historical."],
          "findings" => []
        },
        %{
          "lifecycle_id" => lifecycle_id,
          "transition_id" => "#{lifecycle_id}:r2:p1:REVIEWER:revise",
          "role" => "REVIEWER",
          "from_role" => "REVIEWER",
          "outcome" => "revise",
          "to_role" => "PLANNER",
          "round" => 2,
          "planning_attempt" => 1,
          "summary" => "The first plan requires a corrective planning attempt.",
          "evidence" => ["Reviewer evidence identifies the missing delivery proof."],
          "findings" => [
            %{
              "severity" => "blocking",
              "summary" => "The exact current plan must be delivered to the Reviewer.",
              "evidence" => [
                "The prior prompt contained an abbreviated nested event map.",
                "The transition identity and corrective plan were not visible."
              ]
            },
            %{
              "severity" => "advisory",
              "summary" => "The prompt must retain historical and current evidence distinctly.",
              "evidence" => [
                "The current handoff follows an earlier plan and a revision request.",
                "The next role needs both provenance and complete nested findings."
              ]
            }
          ]
        },
        %{
          "lifecycle_id" => lifecycle_id,
          "transition_id" => "#{lifecycle_id}:r2:p2:PLANNER:plan_ready",
          "role" => "PLANNER",
          "from_role" => "PLANNER",
          "outcome" => "plan_ready",
          "to_role" => "REVIEWER",
          "round" => 2,
          "planning_attempt" => 2,
          "summary" => current_plan,
          "evidence" => [
            "Verification instructions: compare the rendered prompt with the selected event map.",
            "Verification instructions: assert the Codex turn input contains the same complete JSON."
          ],
          "findings" => [],
          "revision_reconciliation" => %{
            "rejected_planner_transition_id" => "#{lifecycle_id}:r2:p1:PLANNER:plan_ready",
            "reviewer_transition_id" => "#{lifecycle_id}:r2:p1:REVIEWER:revise",
            "finding_responses" => [
              %{
                "finding_ref" => "#{lifecycle_id}:r2:p1:REVIEWER:revise:finding:0",
                "assessment" => "The serializer change preserves the complete selected plan.",
                "plan_excerpt" => "update the bounded serializer"
              },
              %{
                "finding_ref" => "#{lifecycle_id}:r2:p1:REVIEWER:revise:finding:1",
                "assessment" => "The prompt keeps historical events before the current handoff.",
                "plan_excerpt" => "retain the accepted evidence"
              }
            ]
          }
        }
      ]
    }

    expected_handoff = Jason.encode!(handoff, pretty: true)

    for role <- [:pm, :planner, :reviewer, :implementer, :adversary, :archivist] do
      prompt =
        PromptBuilder.build_prompt(issue, role, %{
          handoff: handoff,
          lifecycle_context: %{current_role: "REVIEWER", predecessor: "PLANNER", round: 2},
          runtime_authority: %{role: role, project_write: role == :implementer}
        })

      assert prompt =~ expected_handoff
      assert prompt =~ "#{lifecycle_id}:r2:p2:PLANNER:plan_ready"
      assert prompt =~ current_plan
      assert prompt =~ "Verification instructions: compare the rendered prompt with the selected event map."
      assert prompt =~ "#{lifecycle_id}:r2:p1:REVIEWER:revise:finding:0"
      refute prompt =~ "%{...}"
      refute prompt =~ "[...]"
    end
  end

  test "prompt builder requires and honors explicit role identity" do
    issue = %Issue{
      identifier: "MT-780",
      title: "instance_config unavailable",
      description: "Missing instance_config file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue, :pm) =~ "You are executing the SYMPHONY role PM."

    assert_raise ArgumentError, fn ->
      PromptBuilder.build_prompt(issue, :pm, %{role_profile: RoleProfiles.profile!(:planner)})
    end
  end

  test "in-repo instance_config.yml is configuration only" do
    instance_config_path = InstanceConfig.instance_config_file_path()
    InstanceConfig.clear_instance_config_file_path()

    issue = %Issue{
      identifier: "MT-616",
      title: "Use plain YAML for instance_config.yml",
      description: "Configuration must not become a prompt source.",
      state: "In Progress",
      url: "https://example.org/issues/MT-616",
      labels: ["configuration"]
    }

    on_exit(fn -> InstanceConfig.set_instance_config_file_path(instance_config_path) end)

    assert {:ok, %{config: config}} = InstanceConfig.load()
    refute Map.has_key?(config, "prompt")

    prompt = PromptBuilder.build_prompt(issue, :archivist, %{handoff: "Archive after convergence."})

    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "You are executing the SYMPHONY role ARCHIVIST."
    assert prompt =~ "Archive after convergence."
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"text\":\"{\\\"schema\\\":\\\"symphony.role-result/v1\\\",\\\"role\\\":\\\"IMPLEMENTER\\\",\\\"outcome\\\":\\\"implementation_complete\\\",\\\"summary\\\":\\\"done\\\",\\\"evidence\\\":[],\\\"findings\\\":[]}\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue, nil, role: :implementer)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              printf '%s\\n' '{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"text\":\"{\\\"schema\\\":\\\"symphony.role-result/v1\\\",\\\"role\\\":\\\"IMPLEMENTER\\\",\\\"outcome\\\":\\\"implementation_complete\\\",\\\"summary\\\":\\\"done\\\",\\\"evidence\\\":[],\\\"findings\\\":[]}\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 role: :implementer,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:role_execution_completed, "issue-live-updates",
                      %{
                        role: :implementer,
                        result: %{
                          "schema" => "symphony.role-result/v1",
                          "role" => "IMPLEMENTER",
                          "outcome" => "implementation_complete"
                        },
                        session_id: "thread-live-turn-live",
                        thread_id: "thread-live",
                        turn_id: "turn-live"
                      }}

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner rejects an invalid role result without reporting completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-invalid-result-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-invalid"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-invalid"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"not valid JSON"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-invalid-result",
        identifier: "MT-INVALID",
        title: "Reject invalid role result",
        description: "Do not report an unvalidated result as a successful completion",
        state: "In Progress",
        labels: ["symphony:role:reviewer"]
      }

      assert_raise RuntimeError, ~r/invalid_role_result/, fn ->
        AgentRunner.run(issue, self(), role: :reviewer)
      end

      assert_receive {:role_execution_failed, "issue-invalid-result", failure}
      assert failure.kind == :role_result_contract
      assert failure.role == :reviewer
      assert {:invalid_role_result, {:role_result_json_decode_error, _}} = failure.reason

      refute_receive {:role_execution_completed, "issue-invalid-result", _completion}
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, role: :implementer, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner performs one role turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      result_message =
        Jason.encode!(%{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" =>
                Jason.encode!(%{
                  "schema" => "symphony.role-result/v1",
                  "role" => "PLANNER",
                  "outcome" => "plan_ready",
                  "summary" => "done",
                  "evidence" => [],
                  "findings" => []
                })
            }
          }
        })

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '#{result_message}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '#{result_message}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Perform one role turn",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: ["symphony:role:planner"]
      }

      handoff = %{
        lifecycle_id: "life-codex-boundary",
        current_role: :planner,
        round: 2,
        planning_attempt: 2,
        accepted_events: [
          %{
            "transition_id" => "life-codex-boundary:r2:p2:PLANNER:plan_ready",
            "role" => "PLANNER",
            "summary" => "Complete corrective plan delivered to the next role.",
            "evidence" => ["Run the independent verification command after dispatch."],
            "findings" => [
              %{
                "severity" => "blocking",
                "summary" => "Preserve the complete nested finding.",
                "evidence" => ["The previous serializer abbreviated this event."]
              }
            ]
          }
        ]
      }

      expected_handoff = Jason.encode!(handoff, pretty: true)

      assert :ok = AgentRunner.run(issue, nil, role: :planner, handoff: handoff)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 1
      assert Enum.at(turn_texts, 0) =~ "You are executing the SYMPHONY role PLANNER."
      assert Enum.at(turn_texts, 0) =~ expected_handoff
      refute Enum.at(turn_texts, 0) =~ "%{...}"
      refute Enum.at(turn_texts, 0) =~ "[...]"
      refute Enum.at(turn_texts, 0) =~ "Continuation guidance:"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner performs exactly one role turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      result_message =
        Jason.encode!(%{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "agentMessage",
              "text" =>
                Jason.encode!(%{
                  "schema" => "symphony.role-result/v1",
                  "role" => "REVIEWER",
                  "outcome" => "accept",
                  "summary" => "done",
                  "evidence" => [],
                  "findings" => []
                })
            }
          }
        })

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '#{result_message}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Perform one role execution",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: ["symphony:role:reviewer"]
      }

      assert :ok = AgentRunner.run(issue, nil, role: :reviewer)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            printf '%s\\n' '{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"text\":\"assistant output\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from instance_config config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            printf '%s\\n' '{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"text\":\"assistant output\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from instance_config config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"assistant output"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
