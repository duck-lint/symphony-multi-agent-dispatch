defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @thread_resume_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @pending_response_messages_key {__MODULE__, :pending_response_messages}
  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          thread_path: Path.t() | nil,
          workspace: Path.t(),
          worker_host: String.t() | nil,
          dynamic_tool_binding: map(),
          role_bound: boolean(),
          authority_snapshot: map() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    requested_thread_id = Keyword.get(opts, :thread_id)
    requested_thread_path = Keyword.get(opts, :thread_path)
    role_policy = Keyword.get(opts, :role_policy)
    dynamic_tool_binding = DynamicTool.bind()
    role_dynamic_tool_binding = effective_dynamic_tool_binding(dynamic_tool_binding, role_policy)

    with :ok <- validate_role_policy_binding(Keyword.get(opts, :role), role_policy, workspace),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, role_policy),
         {:ok, port} <- start_port(expanded_workspace, worker_host, role_dynamic_tool_binding) do
      case do_start_session(
             port,
             expanded_workspace,
             session_policies,
             role_dynamic_tool_binding,
             requested_thread_id,
             requested_thread_path
           ) do
        {:ok, %{thread_id: thread_id, thread_path: thread_path}} ->
          metadata =
            port_metadata(port, worker_host)
            |> maybe_put_authority_snapshot(role_policy)

          {:ok,
           %{
             port: port,
             metadata: metadata,
             approval_policy: session_policies.approval_policy,
             # A role-bound session never turns Codex approval into a second
             # authority channel. The sandbox is the authority boundary; an
             # approval request is therefore surfaced as a failed turn.
             auto_approve_requests: is_nil(role_policy) and session_policies.approval_policy == "never",
             thread_sandbox: session_policies.thread_sandbox,
             turn_sandbox_policy: session_policies.turn_sandbox_policy,
             thread_id: thread_id,
             thread_path: thread_path,
             workspace: expanded_workspace,
             worker_host: worker_host,
             dynamic_tool_binding: role_dynamic_tool_binding,
             role_bound: not is_nil(role_policy),
             authority_snapshot: authority_snapshot(role_policy)
           }}

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          dynamic_tool_binding: dynamic_tool_binding,
          role_bound: role_bound
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get(opts, :tool_executor, default_tool_executor(dynamic_tool_binding, issue, role_bound))

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
          {:ok, assistant_text} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               assistant_text: assistant_text,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, {:turn_start_failed, reason}}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, dynamic_tool_binding) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(local_launch_command(dynamic_tool_binding))],
            cd: String.to_charlist(workspace),
            env: tracker_secret_port_env(dynamic_tool_binding),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, dynamic_tool_binding) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, dynamic_tool_binding)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp local_launch_command(dynamic_tool_binding) do
    [
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, dynamic_tool_binding) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      tracker_secret_unset_command(dynamic_tool_binding),
      "exec #{Config.settings!().codex.command}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp tracker_secret_port_env(dynamic_tool_binding) do
    dynamic_tool_binding.secret_environment_names
    |> valid_environment_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp tracker_secret_unset_command(dynamic_tool_binding) do
    case dynamic_tool_binding.secret_environment_names |> valid_environment_names() do
      [] -> nil
      names -> "unset " <> Enum.join(names, " ")
    end
  end

  defp valid_environment_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, nil) do
    Config.codex_runtime_settings(workspace)
  end

  defp session_policies(workspace, worker_host, nil) when is_binary(worker_host) do
    Config.codex_runtime_settings(workspace, remote: true)
  end

  defp session_policies(_workspace, _worker_host, %{thread_sandbox: thread_sandbox, turn_sandbox_policy: turn_sandbox_policy})
       when is_binary(thread_sandbox) and is_map(turn_sandbox_policy) do
    {:ok,
     %{
       # Approval policy remains a mechanical setting. It cannot widen the
       # already-bound sandbox policy sent for this role.
       approval_policy: Config.settings!().codex.approval_policy,
       thread_sandbox: thread_sandbox,
       turn_sandbox_policy: turn_sandbox_policy
     }}
  end

  defp session_policies(_workspace, _worker_host, _role_policy),
    do: {:error, :invalid_role_runtime_policy}

  defp effective_dynamic_tool_binding(binding, nil), do: binding

  defp effective_dynamic_tool_binding(binding, _role_policy) when is_map(binding) do
    # Keep the bound secret names for process scrubbing, but never advertise
    # or execute provider-native tracker tools from a lifecycle role.
    Map.put(binding, :tool_specs, [])
  end

  defp default_tool_executor(_binding, _issue, true) do
    fn _tool, _arguments -> DynamicTool.disabled_response() end
  end

  defp default_tool_executor(binding, issue, false) do
    fn tool, arguments -> DynamicTool.execute(tool, arguments, binding, issue: issue) end
  end

  defp validate_role_policy_binding(nil, nil, _workspace), do: :ok

  defp validate_role_policy_binding(nil, _role_policy, _workspace),
    do: {:error, :role_runtime_policy_requires_canonical_role}

  defp validate_role_policy_binding(role, %{role: role} = role_policy, workspace) do
    SymphonyElixir.RoleRuntimePolicy.validate(role, role_policy, workspace)
  end

  defp validate_role_policy_binding(_role, _role_policy, _workspace),
    do: {:error, :role_runtime_policy_mismatch}

  defp maybe_put_authority_snapshot(metadata, nil), do: metadata

  defp maybe_put_authority_snapshot(metadata, role_policy) when is_map(role_policy) do
    Map.put(metadata, :authority_snapshot, SymphonyElixir.RoleRuntimePolicy.snapshot(role_policy))
  end

  defp authority_snapshot(nil), do: nil
  defp authority_snapshot(role_policy), do: SymphonyElixir.RoleRuntimePolicy.snapshot(role_policy)

  defp do_start_session(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         requested_thread_id,
         requested_thread_path
       ) do
    case send_initialize(port) do
      :ok ->
        start_or_reuse_thread(
          port,
          workspace,
          session_policies,
          dynamic_tool_binding,
          requested_thread_id,
          requested_thread_path
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_or_reuse_thread(
         port,
         workspace,
         session_policies,
         dynamic_tool_binding,
         nil,
         _requested_thread_path
       ),
       do: start_thread(port, workspace, session_policies, dynamic_tool_binding)

  defp start_or_reuse_thread(
         port,
         workspace,
         session_policies,
         _dynamic_tool_binding,
         thread_id,
         thread_path
       )
       when is_binary(thread_id) do
    if valid_requested_thread_id?(thread_id) do
      resume_thread(port, workspace, session_policies, String.trim(thread_id), thread_path)
    else
      {:error, :invalid_thread_id}
    end
  end

  defp start_or_reuse_thread(
         _port,
         _workspace,
         _session_policies,
         _dynamic_tool_binding,
         _thread_id,
         _thread_path
       ),
       do: {:error, :invalid_thread_id}

  defp valid_requested_thread_id?(thread_id) do
    String.trim(thread_id) != "" and
      not String.contains?(thread_id, ["\n", "\r", <<0>>])
  end

  defp start_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         dynamic_tool_binding
       ) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => dynamic_tool_binding.tool_specs
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} when is_binary(thread_id) and thread_id != "" ->
            {:ok, %{thread_id: thread_id, thread_path: thread_path(thread_payload)}}

          _ ->
            {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp resume_thread(
         port,
         workspace,
         %{approval_policy: approval_policy, thread_sandbox: thread_sandbox},
         thread_id,
         requested_thread_path
       ) do
    params =
      %{
        "threadId" => thread_id,
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace
      }
      |> maybe_put_thread_path(requested_thread_path)

    send_message(port, %{
      "method" => "thread/resume",
      "id" => @thread_resume_id,
      "params" => params
    })

    case await_response(port, @thread_resume_id) do
      {:ok, %{"thread" => %{"id" => ^thread_id} = thread_payload}} ->
        {:ok, %{thread_id: thread_id, thread_path: thread_path(thread_payload)}}

      {:ok, %{"thread" => %{"id" => resumed_thread_id}}} ->
        {:error, {:thread_resume_id_mismatch, thread_id, resumed_thread_id}}

      {:ok, %{"thread" => thread_payload}} ->
        {:error, {:invalid_thread_payload, thread_payload}}

      other ->
        other
    end
  end

  defp thread_path(%{"path" => path}) when is_binary(path) and path != "", do: path
  defp thread_path(_thread_payload), do: nil

  defp maybe_put_thread_path(params, path) when is_binary(path) and path != "" do
    Map.put(params, "path", path)
  end

  defp maybe_put_thread_path(params, _path), do: params

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      []
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests,
         completed_agent_messages
       ) do
    case take_pending_response_message(port) do
      {:ok, data} ->
        handle_incoming(
          port,
          on_message,
          data,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          completed_agent_messages
        )

      :empty ->
        receive do
          {^port, {:data, {:eol, chunk}}} ->
            complete_line = pending_line <> to_string(chunk)

            handle_incoming(
              port,
              on_message,
              complete_line,
              timeout_ms,
              tool_executor,
              auto_approve_requests,
              completed_agent_messages
            )

          {^port, {:data, {:noeol, chunk}}} ->
            receive_loop(
              port,
              on_message,
              timeout_ms,
              pending_line <> to_string(chunk),
              tool_executor,
              auto_approve_requests,
              completed_agent_messages
            )

          {^port, {:exit_status, status}} ->
            {:error, {:port_exit, status}}
        after
          timeout_ms ->
            {:error, :turn_timeout}
        end
    end
  end

  defp handle_incoming(
         port,
         on_message,
         data,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         completed_agent_messages
       ) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, payload} ->
        handle_decoded_message(
          port,
          on_message,
          payload,
          payload_string,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          completed_agent_messages
        )

      {:error, _reason} ->
        handle_malformed_message(
          port,
          on_message,
          payload_string,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          completed_agent_messages
        )
    end
  end

  defp handle_decoded_message(
         port,
         on_message,
         %{"method" => "turn/completed"} = payload,
         payload_string,
         _timeout_ms,
         _tool_executor,
         _auto_approve_requests,
         completed_agent_messages
       ) do
    emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)

    case final_agent_message(completed_agent_messages) do
      {:ok, assistant_text} -> {:ok, assistant_text}
      :error -> {:error, :turn_completed_without_agent_message}
    end
  end

  defp handle_decoded_message(
         port,
         on_message,
         %{"method" => method} = payload,
         payload_string,
         _timeout_ms,
         _tool_executor,
         _auto_approve_requests,
         _completed_agent_messages
       )
       when method in ["turn/failed", "turn/cancelled"] do
    event = if method == "turn/failed", do: :turn_failed, else: :turn_cancelled
    reason = if method == "turn/failed", do: :turn_failed, else: :turn_cancelled
    details = Map.get(payload, "params")
    emit_turn_event(on_message, event, payload, payload_string, port, details)
    {:error, {reason, details}}
  end

  defp handle_decoded_message(
         port,
         on_message,
         %{"method" => method} = payload,
         payload_string,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         completed_agent_messages
       )
       when is_binary(method) do
    if method == "item/completed" do
      emit_message(
        on_message,
        :notification,
        %{payload: payload, raw: payload_string},
        metadata_from_message(port, payload)
      )

      continue_receiving(
        port,
        on_message,
        timeout_ms,
        tool_executor,
        auto_approve_requests,
        collect_agent_message(completed_agent_messages, payload)
      )
    else
      handle_turn_method(
        port,
        on_message,
        payload,
        payload_string,
        method,
        %{
          timeout_ms: timeout_ms,
          tool_executor: tool_executor,
          auto_approve_requests: auto_approve_requests,
          completed_agent_messages: completed_agent_messages
        }
      )
    end
  end

  defp handle_decoded_message(
         port,
         on_message,
         payload,
         payload_string,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         completed_agent_messages
       ) do
    emit_message(
      on_message,
      :other_message,
      %{payload: payload, raw: payload_string},
      metadata_from_message(port, payload)
    )

    continue_receiving(
      port,
      on_message,
      timeout_ms,
      tool_executor,
      auto_approve_requests,
      completed_agent_messages
    )
  end

  defp handle_malformed_message(
         port,
         on_message,
         payload_string,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         completed_agent_messages
       ) do
    log_non_json_stream_line(payload_string, "turn stream")

    if protocol_message_candidate?(payload_string) do
      emit_message(
        on_message,
        :malformed,
        %{payload: payload_string, raw: payload_string},
        metadata_from_message(port, %{raw: payload_string})
      )
    end

    continue_receiving(
      port,
      on_message,
      timeout_ms,
      tool_executor,
      auto_approve_requests,
      completed_agent_messages
    )
  end

  defp continue_receiving(port, on_message, timeout_ms, tool_executor, auto_approve_requests, messages) do
    receive_loop(port, on_message, timeout_ms, "", tool_executor, auto_approve_requests, messages)
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(port, on_message, payload, payload_string, method, runtime) do
    %{
      timeout_ms: timeout_ms,
      tool_executor: tool_executor,
      auto_approve_requests: auto_approve_requests,
      completed_agent_messages: completed_agent_messages
    } = runtime

    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          completed_agent_messages
        )

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")

          receive_loop(
            port,
            on_message,
            timeout_ms,
            "",
            tool_executor,
            auto_approve_requests,
            completed_agent_messages
          )
        end
    end
  end

  defp collect_agent_message(messages, %{
         "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
       })
       when is_list(messages) and is_binary(text),
       do: messages ++ [text]

  defp collect_agent_message(messages, _payload), do: messages

  defp final_agent_message(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn text -> is_binary(text) and String.trim(text) != "" end)
    |> case do
      text when is_binary(text) -> {:ok, text}
      _ -> :error
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_requests
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         _port,
         _id,
         _params,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ),
       do: :input_required

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    if String.starts_with?(question_id, "mcp_tool_call_approval_") do
      case tool_request_user_input_approval_option_label(options) do
        nil -> :error
        answer_label -> {:ok, question_id, answer_label}
      end
    else
      :error
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        stash_pending_response_message(port, payload)
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp stash_pending_response_message(port, payload) do
    key = {@pending_response_messages_key, port}
    Process.put(key, Process.get(key, []) ++ [payload])
  end

  defp take_pending_response_message(port) do
    key = {@pending_response_messages_key, port}

    case Process.get(key, []) do
      [payload | rest] ->
        Process.put(key, rest)
        {:ok, payload}

      [] ->
        :empty
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
