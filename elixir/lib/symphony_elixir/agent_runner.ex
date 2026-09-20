defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer

  alias SymphonyElixir.{
    Config,
    EnvironmentCapabilities,
    Lifecycle,
    PMThreadState,
    PromptBuilder,
    RoleProfiles,
    RoleRuntimePolicy,
    Workspace
  }

  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    role = Keyword.fetch!(opts, :role)
    role_profile = Keyword.get(opts, :role_profile, RoleProfiles.profile!(role))
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info(
      "Starting #{RoleProfiles.role_name(role)} agent run for #{issue_context(issue)} " <>
        "worker_host=#{worker_host_for_log(worker_host)}"
    )

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host, role, role_profile) do
      :ok ->
        :ok

      {:error, {:pm_thread_continuity, reason}} ->
        send_pm_continuity_failure(codex_update_recipient, issue, reason)
        Logger.error("PM thread continuity failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "PM thread continuity failed for #{issue_context(issue)}: #{inspect(reason)}"

      {:error, {:role_result_contract, role, reason}} ->
        failure = {:invalid_role_result, reason}
        send_role_result_failure(codex_update_recipient, issue, role, failure)

        Logger.error(
          "Role result contract failed for #{issue_context(issue)} role=#{RoleProfiles.role_name(role)}: " <>
            "#{inspect(failure)}"
        )

        raise RuntimeError,
              "Role result contract failed for #{issue_context(issue)} role=#{RoleProfiles.role_name(role)}: #{inspect(failure)}"

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host, role, role_profile) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        with {:ok, role_policy} <- RoleRuntimePolicy.for_role(role, workspace, worker_host: worker_host),
             {:ok, boundary} <- Workspace.enforce_role_boundary(workspace, role_policy, worker_host) do
          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
                 {:ok, source_provenance} <- Workspace.verify_source_provenance(workspace, worker_host),
                 {:ok, capability_report} <- EnvironmentCapabilities.verify(workspace, worker_host) do
              send_worker_runtime_info(
                codex_update_recipient,
                issue,
                worker_host,
                workspace,
                role_policy,
                boundary,
                source_provenance
              )

              run_role_turn(
                workspace,
                issue,
                codex_update_recipient,
                opts
                |> Keyword.put(:environment_capabilities, capability_report)
                |> Keyword.put(:source_provenance, source_provenance),
                worker_host,
                role,
                role_profile,
                role_policy
              )
            end
          after
            Workspace.run_after_run_hook(workspace, issue, worker_host)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(
         recipient,
         %Issue{id: issue_id},
         worker_host,
         workspace,
         role_policy,
         boundary,
         source_provenance
       )
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) and is_map(role_policy) and
              is_map(boundary) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         authority_snapshot:
           RoleRuntimePolicy.snapshot(role_policy)
           |> Map.put(:git_metadata_boundary, boundary.git_metadata_protection),
         source_provenance: source_provenance
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _role_policy, _boundary, _source_provenance), do: :ok

  defp run_role_turn(
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         role,
         role_profile,
         role_policy
       ) do
    with {:ok, thread_selection} <- resolve_thread_selection(issue, role, opts),
         {:ok, session} <- start_role_session(workspace, worker_host, thread_selection, role_policy) do
      try do
        with :ok <- persist_new_pm_thread(issue, thread_selection, session) do
          case run_role_turn_with_session(
                 session,
                 workspace,
                 issue,
                 codex_update_recipient,
                 opts,
                 role,
                 role_profile,
                 role_policy
               ) do
            {:ok, turn_session} ->
              send_role_execution_completed(
                codex_update_recipient,
                issue,
                role,
                turn_session,
                turn_session.result
              )

              :ok

            {:error, reason} ->
              normalize_role_turn_error(thread_selection, reason)
          end
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_role_turn_with_session(
         session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         role,
         role_profile,
         role_policy
       ) do
    prompt_context = %{
      role_profile: role_profile,
      handoff: Keyword.get(opts, :handoff),
      runtime_authority: RoleRuntimePolicy.snapshot(role_policy),
      lifecycle_context: Keyword.get(opts, :lifecycle_context),
      correction_feedback: Keyword.get(opts, :correction_feedback),
      environment_capabilities: Keyword.get(opts, :environment_capabilities),
      source_provenance: Keyword.get(opts, :source_provenance)
    }

    prompt = PromptBuilder.build_prompt(issue, role, prompt_context)

    case AppServer.run_turn(
           session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
      {:ok, turn_session} ->
        case Lifecycle.decode_and_validate_result(turn_session[:assistant_text], role) do
          {:ok, result} ->
            Logger.info(
              "Completed #{RoleProfiles.role_name(role)} role execution for #{issue_context(issue)} " <>
                "session_id=#{turn_session[:session_id]} workspace=#{workspace}"
            )

            {:ok, Map.put(turn_session, :result, result)}

          {:error, reason} ->
            Logger.warning("Invalid #{RoleProfiles.role_name(role)} role result for #{issue_context(issue)}: #{inspect(reason)}")

            {:error, {:role_result_contract, role, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_thread_selection(%Issue{id: issue_id}, :pm, opts) do
    lifecycle_id = Keyword.get(opts, :lifecycle_id)
    phase = Keyword.get(opts, :pm_phase)

    if is_binary(lifecycle_id) and phase in [:initial, :returning] do
      case PMThreadState.resolve(issue_id, lifecycle_id, phase) do
        {:resume, thread_id, thread_path} ->
          {:ok,
           %{
             kind: :pm,
             thread_id: thread_id,
             thread_path: thread_path,
             persist?: false,
             lifecycle_id: lifecycle_id
           }}

        {:new, _reason} ->
          {:ok, %{kind: :pm, thread_id: nil, persist?: true, lifecycle_id: lifecycle_id}}

        {:error, reason} ->
          {:error, {:pm_thread_continuity, reason}}
      end
    else
      {:error, {:pm_thread_continuity, :invalid_lifecycle_binding}}
    end
  end

  defp resolve_thread_selection(%Issue{}, _role, _opts), do: {:ok, %{kind: :specialist}}

  defp start_role_session(workspace, worker_host, %{kind: :specialist}, role_policy) do
    AppServer.start_session(workspace, worker_host: worker_host, role: role_policy.role, role_policy: role_policy)
  end

  defp start_role_session(workspace, worker_host, %{kind: :pm, thread_id: nil}, role_policy) do
    AppServer.start_session(workspace, worker_host: worker_host, role: role_policy.role, role_policy: role_policy)
  end

  defp start_role_session(
         workspace,
         worker_host,
         %{kind: :pm, thread_id: thread_id, thread_path: thread_path},
         role_policy
       ) do
    case AppServer.start_session(workspace,
           worker_host: worker_host,
           thread_id: thread_id,
           thread_path: thread_path,
           role: role_policy.role,
           role_policy: role_policy
         ) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        {:error, {:pm_thread_continuity, {:required_thread_unavailable, reason}}}
    end
  end

  defp persist_new_pm_thread(
         %Issue{id: issue_id},
         %{kind: :pm, persist?: true, lifecycle_id: lifecycle_id},
         session
       ) do
    case PMThreadState.put(issue_id, lifecycle_id, session.thread_id, thread_path: session.thread_path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:pm_thread_continuity, {:thread_state_persist_failed, reason}}}
    end
  end

  defp persist_new_pm_thread(_issue, _selection, _session), do: :ok

  defp normalize_role_turn_error(
         %{kind: :pm, thread_id: thread_id},
         {:turn_start_failed, reason}
       )
       when is_binary(thread_id) do
    {:error, {:pm_thread_continuity, {:required_thread_unavailable, reason}}}
  end

  defp normalize_role_turn_error(_selection, reason), do: {:error, reason}

  defp send_pm_continuity_failure(recipient, %Issue{id: issue_id}, reason)
       when is_pid(recipient) and is_binary(issue_id) do
    send(
      recipient,
      {:role_execution_failed, issue_id, %{kind: :pm_continuity, role: :pm, reason: reason}}
    )
  end

  defp send_pm_continuity_failure(_recipient, _issue, _reason), do: :ok

  defp send_role_result_failure(recipient, %Issue{id: issue_id}, role, reason)
       when is_pid(recipient) and is_binary(issue_id) do
    send(
      recipient,
      {:role_execution_failed, issue_id, %{kind: :role_result_contract, role: role, reason: reason}}
    )
  end

  defp send_role_result_failure(_recipient, _issue, _role, _reason), do: :ok

  defp send_role_execution_completed(
         recipient,
         %Issue{id: issue_id},
         role,
         %{session_id: session_id, thread_id: thread_id, turn_id: turn_id},
         result
       )
       when is_pid(recipient) and is_binary(issue_id) do
    send(
      recipient,
      {:role_execution_completed, issue_id,
       %{
         role: role,
         result: result,
         session_id: session_id,
         thread_id: thread_id,
         turn_id: turn_id
       }}
    )
  end

  defp send_role_execution_completed(_recipient, _issue, _role, _turn_session, _result), do: :ok

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
