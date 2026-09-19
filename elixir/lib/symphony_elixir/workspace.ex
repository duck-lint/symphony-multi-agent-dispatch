defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_git_boundary_marker "__SYMPHONY_GIT_BOUNDARY__"

  @type worker_host :: String.t() | nil

  @doc """
  Establishes the filesystem boundary required by an Implementer run.

  A workspace-write Codex sandbox cannot express "write this directory except
  `.git`". For a local workspace, the authoritative Git directory is therefore
  moved to a deterministic sibling outside the writable root and `.git` becomes
  only a pointer. Remote workers use the equivalent shell operation. Failure is
  returned before Codex is launched.
  """
  @spec enforce_role_boundary(Path.t(), map(), worker_host()) ::
          {:ok, map()} | {:error, term()}
  def enforce_role_boundary(workspace, %{git_metadata_protection: :required}, nil)
      when is_binary(workspace) do
    protect_local_git_metadata(workspace)
  end

  def enforce_role_boundary(workspace, %{git_metadata_protection: :required}, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    protect_remote_git_metadata(workspace, worker_host)
  end

  def enforce_role_boundary(_workspace, %{git_metadata_protection: :not_required}, _worker_host) do
    {:ok, %{git_metadata_protection: :not_required}}
  end

  def enforce_role_boundary(_workspace, _policy, _worker_host) do
    {:error, {:role_workspace_boundary, :invalid_policy}}
  end

  @doc false
  @spec protected_git_metadata_path(Path.t()) :: Path.t()
  def protected_git_metadata_path(workspace) when is_binary(workspace) do
    key =
      :crypto.hash(:sha256, Path.expand(workspace))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    Path.join([Path.dirname(Path.expand(workspace)), ".symphony-git-metadata", key])
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, worker_host)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)
    remove_protected_git_metadata(workspace)
    File.rm_rf(workspace)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @doc false
  @spec workspace_resource_available?(String.t(), String.t(), worker_host()) ::
          :ok | {:error, term()}
  def workspace_resource_available?(workspace, relative_path, nil)
      when is_binary(workspace) and is_binary(relative_path) do
    with {:ok, path} <- local_workspace_path(workspace, relative_path, false) do
      if File.exists?(path), do: :ok, else: {:error, :unavailable}
    end
  end

  def workspace_resource_available?(workspace, relative_path, worker_host)
      when is_binary(workspace) and is_binary(relative_path) and is_binary(worker_host) do
    path = Path.join(workspace, relative_path)

    case run_remote_command(worker_host, "test -e -- #{shell_escape(path)}", Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, _status}} -> {:error, :unavailable}
      {:error, {:workspace_hook_timeout, _hook_name, timeout_ms}} -> {:error, {:timeout, timeout_ms}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec run_verification_command(String.t(), String.t(), map(), worker_host()) ::
          :ok | {:error, term()}
  def run_verification_command(workspace, working_directory, command, nil)
      when is_binary(workspace) and is_binary(working_directory) and is_map(command) do
    executable = Map.fetch!(command, "executable")
    args = Map.get(command, "args", [])

    with {:ok, directory} <- local_workspace_path(workspace, working_directory, true),
         {:ok, executable} <- local_command_executable(workspace, executable) do
      task =
        Task.async(fn ->
          try do
            {:ok, System.cmd(executable, args, cd: directory, stderr_to_stdout: true)}
          rescue
            _error -> {:error, :unavailable}
          end
        end)

      case Task.yield(task, Config.settings!().hooks.timeout_ms) do
        {:ok, {:ok, {_output, 0}}} ->
          :ok

        {:ok, {:ok, {_output, status}}} ->
          {:error, {:failed, status}}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:exit, _reason} ->
          {:error, :unavailable}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, {:timeout, Config.settings!().hooks.timeout_ms}}
      end
    end
  end

  def run_verification_command(workspace, working_directory, command, worker_host)
      when is_binary(workspace) and is_binary(working_directory) and is_map(command) and
             is_binary(worker_host) do
    executable = Map.fetch!(command, "executable")
    args = Map.get(command, "args", [])

    command_line =
      [remote_command_executable(workspace, executable) | args]
      |> Enum.map_join(" ", &shell_escape/1)

    script = "cd #{shell_escape(Path.join(workspace, working_directory))} && #{command_line}"

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, status}} -> {:error, {:failed, status}}
      {:error, {:workspace_hook_timeout, _hook_name, timeout_ms}} -> {:error, {:timeout, timeout_ms}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp local_workspace_path(workspace, relative_path, allow_current_directory?) do
    if safe_workspace_relative_path?(relative_path, allow_current_directory?) do
      with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
           {:ok, canonical_path} <- PathSafety.canonicalize(Path.join(canonical_workspace, relative_path)),
           true <- path_within_workspace?(canonical_path, canonical_workspace) do
        {:ok, canonical_path}
      else
        false -> {:error, :unsafe_path}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unsafe_path}
    end
  end

  defp local_command_executable(workspace, executable) do
    if String.contains?(executable, "/") do
      local_workspace_path(workspace, executable, false)
    else
      {:ok, executable}
    end
  end

  defp remote_command_executable(workspace, executable) do
    if String.contains?(executable, "/") do
      Path.join(workspace, executable)
    else
      executable
    end
  end

  defp safe_workspace_relative_path?(path, allow_current_directory?) do
    path != "" and (allow_current_directory? or path != ".") and
      not String.contains?(path, <<0>>) and
      not String.contains?(path, "\\") and
      Path.type(path) != :absolute and
      not Enum.any?(String.split(path, "/"), &(&1 in ["", ".."]))
  end

  defp path_within_workspace?(path, workspace) do
    path == workspace or String.starts_with?(path, workspace <> "/")
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host) when is_binary(worker_host) do
    script = [remote_shell_assign("workspace", workspace), "rm -rf \"$workspace\""] |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp protect_local_git_metadata(workspace) do
    git_path = Path.join(Path.expand(workspace), ".git")

    case File.lstat(git_path) do
      {:error, :enoent} ->
        {:ok, %{git_metadata_protection: :not_present}}

      {:error, reason} ->
        {:error, {:role_workspace_boundary, :git_metadata_unreadable, reason}}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:role_workspace_boundary, :git_metadata_symlink}}

      {:ok, %File.Stat{type: :directory}} ->
        external_git_dir = protected_git_metadata_path(workspace)

        with :ok <- ensure_external_git_path(external_git_dir, workspace),
             :ok <- File.mkdir_p(Path.dirname(external_git_dir)),
             :ok <- move_git_directory(git_path, external_git_dir),
             :ok <- write_git_pointer(git_path, external_git_dir) do
          {:ok, %{git_metadata_protection: :externalized}}
        else
          {:error, reason} -> {:error, {:role_workspace_boundary, reason}}
        end

      {:ok, %File.Stat{type: :regular}} ->
        validate_existing_git_pointer(git_path, workspace)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:role_workspace_boundary, :unsupported_git_metadata_type, type}}
    end
  rescue
    error in [ArgumentError, ErlangError, File.Error] ->
      {:error, {:role_workspace_boundary, :git_metadata_protection_failed, error}}
  end

  defp ensure_external_git_path(external_git_dir, workspace) do
    with :ok <- File.mkdir_p(Path.dirname(external_git_dir)),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(Path.expand(workspace)),
         :ok <- reject_external_path_inside_workspace(external_git_dir, canonical_workspace) do
      if File.exists?(external_git_dir) do
        {:error, {:external_git_metadata_exists, external_git_dir}}
      else
        :ok
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_external_path_inside_workspace(external_git_dir, canonical_workspace) do
    expanded_external = Path.expand(external_git_dir)

    case PathSafety.canonicalize(Path.dirname(expanded_external)) do
      {:ok, canonical_parent} ->
        canonical_external = Path.join(canonical_parent, Path.basename(expanded_external))
        normalized_external = normalize_comparison_path(canonical_external)
        normalized_workspace = normalize_comparison_path(canonical_workspace)

        if normalized_external == normalized_workspace or
             String.starts_with?(normalized_external <> "/", normalized_workspace <> "/") do
          {:error, {:external_git_metadata_inside_workspace, canonical_external}}
        else
          :ok
        end

      {:error, reason} ->
        {:error, {:external_git_metadata_parent_unreadable, reason}}
    end
  end

  defp normalize_comparison_path(path) when is_binary(path) do
    normalized = path |> Path.expand() |> String.replace("\\", "/")

    if :os.type() == {:win32, :nt}, do: String.downcase(normalized), else: normalized
  end

  defp move_git_directory(git_path, external_git_dir) do
    case File.rename(git_path, external_git_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:git_metadata_move_failed, reason}}
    end
  end

  defp write_git_pointer(git_path, external_git_dir) do
    pointer_path = git_path <> ".symphony-pointer"
    pointer = "gitdir: #{String.replace(external_git_dir, "\\", "/")}\n"

    with :ok <- File.write(pointer_path, pointer),
         :ok <- File.rename(pointer_path, git_path) do
      :ok
    else
      {:error, reason} -> {:error, {:git_pointer_write_failed, reason}}
    end
  end

  defp validate_existing_git_pointer(git_path, workspace) do
    with {:ok, content} <- File.read(git_path),
         {:ok, external_git_dir} <- parse_git_pointer(content, git_path),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(Path.expand(workspace)),
         {:ok, canonical_git_dir} <- PathSafety.canonicalize(external_git_dir),
         :ok <- reject_external_path_inside_workspace(canonical_git_dir, canonical_workspace),
         true <- File.dir?(canonical_git_dir) do
      {:ok, %{git_metadata_protection: :already_externalized}}
    else
      {:error, reason} -> {:error, {:role_workspace_boundary, reason}}
      false -> {:error, {:role_workspace_boundary, :git_pointer_target_not_directory}}
    end
  end

  defp remove_protected_git_metadata(workspace) do
    expected_git_dir = Path.expand(protected_git_metadata_path(workspace))
    git_path = Path.join(Path.expand(workspace), ".git")

    with {:ok, content} <- File.read(git_path),
         {:ok, git_dir} <- parse_git_pointer(content, git_path),
         true <- Path.expand(git_dir) == expected_git_dir do
      case File.rm_rf(expected_git_dir) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> Logger.warning("Failed to remove protected Git metadata reason=#{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp parse_git_pointer(content, git_path) when is_binary(content) do
    case Regex.run(~r/^gitdir:\s*(.+)\s*$/m, content, capture: :all_but_first) do
      [raw_path] ->
        path = String.trim(raw_path)

        if Path.type(path) == :absolute do
          {:ok, Path.expand(path)}
        else
          {:ok, Path.expand(path, Path.dirname(git_path))}
        end

      _ ->
        {:error, :invalid_git_pointer}
    end
  end

  defp protect_remote_git_metadata(workspace, worker_host) do
    external_git_dir = protected_git_metadata_path(workspace)
    key = Path.basename(external_git_dir)

    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "git_path=\"$workspace/.git\"",
        "metadata_root=\"$workspace/../.symphony-git-metadata\"",
        "metadata=\"$metadata_root/#{key}\"",
        "if [ -L \"$git_path\" ]; then exit 41; fi",
        "if [ -d \"$git_path\" ]; then",
        "  if [ -e \"$metadata\" ]; then exit 42; fi",
        "  mkdir -p \"$metadata_root\"",
        "  mv \"$git_path\" \"$metadata\"",
        "  printf 'gitdir: %s\\n' \"$metadata\" > \"$git_path\"",
        "elif [ -f \"$git_path\" ]; then",
        "  gitdir=$(sed -n 's/^gitdir:[[:space:]]*//p' \"$git_path\")",
        "  test -n \"$gitdir\"",
        "  case \"$gitdir\" in /*) ;; *) exit 45 ;; esac",
        "  gitdir_real=$(cd \"$gitdir\" 2>/dev/null && pwd -P)",
        "  workspace_real=$(cd \"$workspace\" 2>/dev/null && pwd -P)",
        "  case \"$gitdir_real\" in \"$workspace_real\"/*) exit 43 ;; esac",
        "elif [ -e \"$git_path\" ]; then",
        "  exit 44",
        "fi",
        "printf '%s\\n' '#{@remote_git_boundary_marker}'"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        if String.contains?(IO.iodata_to_binary(output), @remote_git_boundary_marker) do
          {:ok, %{git_metadata_protection: :externalized}}
        else
          {:error, {:role_workspace_boundary, :invalid_remote_git_boundary_output}}
        end

      {:ok, {_output, status}} ->
        {:error, {:role_workspace_boundary, :remote_git_metadata_protection_failed, status}}

      {:error, reason} ->
        {:error, {:role_workspace_boundary, :remote_git_metadata_protection_failed, reason}}
    end
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
