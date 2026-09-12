defmodule SymphonyElixir.RoleRuntimePolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RoleRuntimePolicy

  @read_only_roles [:pm, :planner, :reviewer, :adversary, :archivist]

  test "all read-only roles receive a read-only, network-disabled policy" do
    Enum.each(@read_only_roles, fn role ->
      assert {:ok, policy} = RoleRuntimePolicy.for_role(role, "/tmp/issue-workspace")
      assert policy.role == role
      assert policy.write_authority == :read_only
      assert policy.thread_sandbox == "read-only"
      assert policy.turn_sandbox_policy == %{"type" => "readOnly", "networkAccess" => false}
      assert policy.network_access == false
      assert policy.git_metadata_protection == :not_required
    end)
  end

  test "implementer receives only the issue workspace as a writable root" do
    workspace = "/tmp/issue-workspace"
    assert {:ok, policy} = RoleRuntimePolicy.for_role(:implementer, workspace)

    assert policy.write_authority == :project_write
    assert policy.thread_sandbox == "workspace-write"
    assert policy.turn_sandbox_policy["type"] == "workspaceWrite"
    assert policy.turn_sandbox_policy["writableRoots"] == [workspace]
    assert policy.turn_sandbox_policy["networkAccess"] == false
    assert policy.git_metadata_protection == :required
  end

  test "policy validation rejects tampering and malformed inputs" do
    workspace = "/tmp/issue-workspace"
    assert {:ok, policy} = RoleRuntimePolicy.for_role(:planner, workspace)

    assert {:error, :role_runtime_policy_tampered} =
             RoleRuntimePolicy.validate(:planner, Map.put(policy, :network_access, true), workspace)

    assert {:error, {:role_runtime_policy, :invalid_workspace}} =
             RoleRuntimePolicy.validate(:planner, policy, "  ")

    assert {:error, :invalid_role_runtime_policy} =
             RoleRuntimePolicy.validate(:planner, :not_a_policy, workspace)
  end

  test "policy construction rejects non-string workspace paths" do
    assert {:error, {:role_runtime_policy, :invalid_workspace}} =
             RoleRuntimePolicy.for_role(:implementer, nil)
  end

  test "configured sandbox and network settings cannot widen a role policy" do
    assert {:ok, policy} = RoleRuntimePolicy.for_role(:planner, "/tmp/issue-workspace")

    # Deliberately broad instance_config values are mechanical input to the
    # old config resolver, never input to this host-owned role binding.
    assert policy.thread_sandbox == "read-only"
    assert policy.turn_sandbox_policy["type"] == "readOnly"
    assert policy.turn_sandbox_policy["networkAccess"] == false
    refute Map.has_key?(policy.turn_sandbox_policy, "writableRoots")
  end

  test "implementer git metadata is externalized outside the writable root" do
    root = Path.join(System.tmp_dir!(), "symphony-role-boundary-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "issue")

    try do
      File.mkdir_p!(Path.join(workspace, ".git"))
      File.write!(Path.join(workspace, "source.txt"), "before")

      assert {:ok, policy} = RoleRuntimePolicy.for_role(:implementer, workspace)

      assert {:ok, %{git_metadata_protection: :externalized}} =
               Workspace.enforce_role_boundary(workspace, policy, nil)

      assert File.regular?(Path.join(workspace, ".git"))
      assert File.dir?(Workspace.protected_git_metadata_path(workspace))

      refute String.starts_with?(
               Path.expand(Workspace.protected_git_metadata_path(workspace)) <> "/",
               Path.expand(workspace) <> "/"
             )

      # The source tree remains writable by the Implementer policy. The
      # authoritative directory is deliberately absent from its writable roots.
      assert policy.turn_sandbox_policy["writableRoots"] == [workspace]
      refute Workspace.protected_git_metadata_path(workspace) in policy.turn_sandbox_policy["writableRoots"]
      File.write!(Path.join(workspace, "source.txt"), "after")
      assert File.read!(Path.join(workspace, "source.txt")) == "after"
    after
      File.rm_rf(root)
    end
  end

  test "unavailable implementer Git containment fails closed" do
    root = Path.join(System.tmp_dir!(), "symphony-role-boundary-invalid-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "issue")

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, ".git"), "not a git pointer")
      assert {:ok, policy} = RoleRuntimePolicy.for_role(:implementer, workspace)

      assert {:error, {:role_workspace_boundary, :invalid_git_pointer}} =
               Workspace.enforce_role_boundary(workspace, policy, nil)
    after
      File.rm_rf(root)
    end
  end

  test "AppServer binds the supplied read-only policy instead of configured broad settings" do
    root = Path.join(System.tmp_dir!(), "symphony-role-app-server-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "issue")
    codex_binary = Path.join(root, "fake-codex")
    trace = Path.join(root, "codex.trace")

    try do
      File.mkdir_p!(workspace)
      trace_path = String.replace(trace, "\\", "/")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "#{trace_path}"
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-policy"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-policy"}}}' ;;
          4)
            printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"role result"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_instance_config_file!(InstanceConfig.instance_config_file_path(),
        workspace_root: root,
        codex_command: "#{codex_binary} app-server",
        codex_thread_sandbox: "danger-full-access",
        codex_turn_sandbox_policy: %{type: "dangerFullAccess", networkAccess: true}
      )

      issue = %Issue{
        id: "issue-role-policy",
        identifier: "MT-ROLE-POLICY",
        title: "Role policy binding",
        description: "Verify role policy reaches App Server",
        state: "In Progress",
        url: "https://example.org/issues/MT-ROLE-POLICY",
        labels: []
      }

      assert {:ok, _result} =
               AppServer.run(
                 workspace,
                 "Use the host policy",
                 issue,
                 role: :planner,
                 role_policy: elem(RoleRuntimePolicy.for_role(:planner, workspace), 1)
               )

      payloads =
        trace
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      thread_start = Enum.find(payloads, &(&1["method"] == "thread/start"))
      turn_start = Enum.find(payloads, &(&1["method"] == "turn/start"))
      assert thread_start["params"]["sandbox"] == "read-only"
      assert thread_start["params"]["dynamicTools"] == []
      assert turn_start["params"]["sandboxPolicy"] == %{"type" => "readOnly", "networkAccess" => false}
    after
      File.rm_rf(root)
    end
  end
end
