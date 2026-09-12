defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PromptBuilder, RoleProfiles, Workspace}
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

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host, role, role_profile) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_role_turn(workspace, issue, codex_update_recipient, opts, worker_host, role, role_profile)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
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

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_role_turn(workspace, issue, codex_update_recipient, opts, worker_host, role, role_profile) do
    with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
      try do
        prompt_context = %{
          role_profile: role_profile,
          handoff: Keyword.get(opts, :handoff)
        }

        prompt = PromptBuilder.build_prompt(issue, role, prompt_context)

        with {:ok, turn_session} <-
               AppServer.run_turn(
                 session,
                 prompt,
                 issue,
                 on_message: codex_message_handler(codex_update_recipient, issue)
               ) do
          Logger.info(
            "Completed #{RoleProfiles.role_name(role)} role execution for #{issue_context(issue)} " <>
              "session_id=#{turn_session[:session_id]} workspace=#{workspace}"
          )

          send_role_execution_completed(codex_update_recipient, issue, role, turn_session)
          :ok
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp send_role_execution_completed(
         recipient,
         %Issue{id: issue_id},
         role,
         %{result: result, session_id: session_id, thread_id: thread_id, turn_id: turn_id}
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

  defp send_role_execution_completed(_recipient, _issue, _role, _turn_session), do: :ok

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
