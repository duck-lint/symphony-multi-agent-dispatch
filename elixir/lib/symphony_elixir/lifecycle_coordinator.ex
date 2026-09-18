defmodule SymphonyElixir.LifecycleCoordinator do
  @moduledoc """
  Host-only GitHub lifecycle initialization, reconstruction, and transition commit.

  This module is deliberately limited to the configured GitHub repository and
  the current issue. It never exposes these operations to role agents.
  """

  require Logger

  alias SymphonyElixir.{
    Config,
    GitHub.Client,
    Lifecycle,
    LifecycleEvidence,
    LifecycleHistory,
    RoleProfiles,
    RoleRouter
  }

  alias SymphonyElixir.Tracker.Issue

  @auto_label "symphony:auto"
  @awaiting_human_label "symphony:state:awaiting-human"
  @lifecycle_complete_label "symphony:state:lifecycle-complete"
  @non_converged_label "symphony:state:non-converged"
  @blocked_label "symphony:state:blocked"
  @state_prefix "symphony:state:"
  @roles [:pm, :planner, :reviewer, :implementer, :adversary, :archivist]

  @spec prepare_dispatch(Issue.t(), keyword()) ::
          {:ok, %{issue: Issue.t(), history: map() | nil, handoff: map(), lifecycle_context: map()}}
          | {:skip, term()}
          | {:error, term()}
  def prepare_dispatch(%Issue{id: issue_id} = issue, _opts \\ []) when is_binary(issue_id) do
    if github_tracker?() do
      prepare_github_dispatch_for_issue(issue_id)
    else
      {:ok, %{issue: issue, history: nil, handoff: %{}, lifecycle_context: %{}}}
    end
  end

  @spec commit_role_result(Issue.t(), RoleProfiles.role(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def commit_role_result(%Issue{id: issue_id}, expected_role, result, _opts \\ [])
      when is_binary(issue_id) and is_map(result) do
    if github_tracker?() do
      commit_github_role_result(issue_id, expected_role, result)
    else
      {:error, :lifecycle_requires_github_tracker}
    end
  end

  @doc false
  @spec correctable_role_result_error?(term()) :: boolean()
  def correctable_role_result_error?(reason) do
    reason in [
      :missing_returning_pm_reconciliation,
      :returning_pm_missing_completed_round_evidence,
      :missing_returning_pm_escalation_evidence,
      :missing_pm_escalation_basis
    ] or
      match?({:invalid_reconciliation_reference, _}, reason) or
      match?({:invalid_escalation_reference, _}, reason)
  end

  @spec block_pm_continuity(Issue.t(), term(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def block_pm_continuity(%Issue{id: issue_id}, reason, _opts \\ [])
      when is_binary(issue_id) do
    if github_tracker?() do
      with {:ok, current_issue} <- github_client().fetch_issue(issue_id),
           :ok <- validate_active_issue(current_issue),
           :ok <- validate_opt_in(current_issue),
           {:ok, :pm} <- RoleRouter.role_for_issue(current_issue),
           :ok <- append_pm_continuity_diagnostic(issue_id, reason),
           :ok <- remove_auto_label(current_issue),
           :ok <- remove_state_labels(current_issue),
           {:ok, _} <- github_client().add_issue_label(issue_id, @blocked_label),
           {:ok, projected_issue} <- github_client().fetch_issue(issue_id),
           :ok <- verify_pm_continuity_block(projected_issue) do
        {:ok, projected_issue}
      else
        {:ok, role} -> {:error, {:pm_continuity_requires_pm_role, role}}
        {:error, _reason} = error -> error
      end
    else
      {:error, :lifecycle_requires_github_tracker}
    end
  end

  @spec block_role_result_contract(Issue.t(), term(), keyword()) :: {:ok, Issue.t()} | {:error, term()}
  def block_role_result_contract(%Issue{id: issue_id}, reason, _opts \\ [])
      when is_binary(issue_id) do
    if github_tracker?(),
      do: block_role_result_contract_on_github(issue_id, reason),
      else: {:error, :lifecycle_requires_github_tracker}
  end

  defp block_role_result_contract_on_github(issue_id, reason) do
    with {:ok, current_issue} <- github_client().fetch_issue(issue_id),
         :ok <- validate_active_issue(current_issue),
         :ok <- validate_opt_in(current_issue) do
      case block_invalid_state(current_issue, nil, {:role_result_contract_exhausted, reason}) do
        {:skip, _blocked} -> {:ok, current_issue}
        {:error, _reason} = error -> error
      end
    end
  end

  defp prepare_github_dispatch_for_issue(issue_id) do
    with {:ok, current_issue} <- github_client().fetch_issue(issue_id),
         {:ok, comments} <- github_client().fetch_issue_comments(issue_id) do
      case LifecycleHistory.from_comments(comments) do
        {:ok, history} -> prepare_github_dispatch(current_issue, history)
        {:error, reason} -> handle_invalid_state(current_issue, nil, reason)
      end
    end
  end

  defp commit_github_role_result(issue_id, expected_role, result) do
    with {:ok, current_issue} <- github_client().fetch_issue(issue_id),
         {:ok, comments} <- github_client().fetch_issue_comments(issue_id) do
      case LifecycleHistory.from_comments(comments) do
        {:ok, history} -> commit_with_history(current_issue, history, expected_role, result)
        {:error, reason} -> commit_invalid_history(current_issue, reason)
      end
    end
  end

  defp commit_invalid_history(current_issue, reason) do
    case block_invalid_state(current_issue, nil, reason) do
      {:skip, _blocked} -> {:error, {:lifecycle_history_corrupt, reason}}
      other -> other
    end
  end

  defp commit_with_history(current_issue, history, expected_role, result) do
    case validate_expected_result(result, expected_role) do
      {:ok, validated_result} ->
        commit_validated_result(current_issue, history, expected_role, validated_result)

      {:error, _reason} = error ->
        error
    end
  end

  defp commit_validated_result(current_issue, history, expected_role, validated_result) do
    case idempotent_result(history, current_issue, validated_result, expected_role) do
      {:ok, _commit} = ok ->
        ok

      :not_found ->
        with :ok <- validate_evidence_reconciliation(history, validated_result) do
          persist_new_transition(current_issue, history, expected_role, validated_result)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_new_transition(current_issue, history, expected_role, validated_result) do
    with :ok <- validate_commit_preconditions(current_issue, history, expected_role),
         {:ok, transition} <- transition_for_commit(history, validated_result),
         {:ok, persisted} <- persist_transition(current_issue, history, transition),
         {:ok, projected_issue} <- project_and_verify(current_issue, transition),
         {:ok, projected_history} <- projected_history_after(persisted, history) do
      {:ok,
       %{
         event: persisted.event,
         idempotent?: persisted.idempotent?,
         issue: projected_issue,
         history: projected_history,
         transition: transition
       }}
    end
  end

  defp idempotent_result(history, issue, result, expected_role) do
    with {:ok, role} <- canonical_role(expected_role),
         event when is_map(event) <-
           Enum.find(history.events, fn event ->
             event["from_role"] == RoleProfiles.role_name(role) and
               event["outcome"] == result["outcome"] and
               event_material_matches_result?(event, result)
           end),
         {:ok, transition} <- transition_from_event(event),
         {:ok, verified_issue} <- project_and_verify(issue, transition) do
      {:ok,
       %{
         event: event,
         idempotent?: true,
         issue: verified_issue,
         history: history,
         transition: transition
       }}
    else
      nil -> :not_found
      :error -> :not_found
      {:error, _reason} = error -> error
    end
  end

  defp event_material_matches_result?(event, result) do
    event["role"] == result["role"] and
      event["role_result_schema"] == result["schema"] and
      Enum.all?(["summary", "evidence", "findings", "prerequisite_resolution"], fn key ->
        Map.get(event, key) == Map.get(result, key)
      end) and
      Map.get(event, "human_question") == Map.get(result, "human_question") and
      Map.get(event, "reconciliation") == Map.get(result, "reconciliation") and
      Map.get(event, "escalation_basis") == Map.get(result, "escalation_basis") and
      (event["kind"] != "terminal" or
         event["terminal_reason"] in expected_terminal_reasons(result))
  end

  defp expected_terminal_reasons(%{"role" => role, "outcome" => "non_converged"})
       when role in ["PLANNER", "REVIEWER"],
       do: ["prerequisite_no_feasible_authorized_path"]

  defp expected_terminal_reasons(%{"role" => "REVIEWER", "outcome" => "revise"}),
    do: ["planning_attempt_exhausted", "prerequisite_non_progress"]

  defp expected_terminal_reasons(%{"role" => "PM", "outcome" => "plan"}),
    do: ["working_round_exhausted"]

  defp expected_terminal_reasons(_result), do: [nil]

  defp transition_from_event(%{"kind" => kind, "from_role" => from_role, "outcome" => outcome, "to_role" => to_role} = event) do
    with {:ok, canonical_from_role} <- canonical_role(from_role),
         {:ok, destination} <- event_destination(to_role) do
      {:ok,
       %{
         kind: kind,
         from_role: canonical_from_role,
         outcome: outcome,
         to_role: destination,
         round: event["round"],
         planning_attempt: event["planning_attempt"],
         result: %{
           "schema" => event["role_result_schema"],
           "role" => event["role"],
           "outcome" => outcome,
           "summary" => event["summary"],
           "evidence" => event["evidence"],
           "findings" => event["findings"],
           "human_question" => event["human_question"],
           "prerequisite_resolution" => Map.get(event, "prerequisite_resolution"),
           "reconciliation" => Map.get(event, "reconciliation"),
           "escalation_basis" => Map.get(event, "escalation_basis")
         }
       }}
    end
  end

  defp transition_from_event(_event), do: {:error, :invalid_persisted_transition}

  defp event_destination("AWAITING_HUMAN"), do: {:ok, :await_human}
  defp event_destination("LIFECYCLE_COMPLETE"), do: {:ok, :lifecycle_complete}
  defp event_destination("NON_CONVERGED"), do: {:ok, :non_converged}
  defp event_destination(role), do: canonical_role(role)

  @spec dispatch_handoff(map()) :: map()
  def dispatch_handoff(%{events: events} = history) when is_list(events) do
    handoff_events =
      if history.current_role == :archivist do
        events
      else
        Enum.filter(events, &(&1["round"] == history.round))
      end

    %{
      lifecycle_id: history.lifecycle_id,
      current_role: history.current_role,
      round: history.round,
      planning_attempt: history.planning_attempt,
      pm_phase: history.pm_phase,
      completed_working_round?: history.completed_working_round?,
      preceding_adversary_findings: history.preceding_adversary_findings,
      prerequisite_context: Lifecycle.prerequisite_context(history),
      reconciliation: LifecycleEvidence.project(history),
      accepted_events: handoff_events
    }
  end

  def dispatch_handoff(_history), do: %{}

  @doc false
  @spec labels_for_test() :: map()
  def labels_for_test do
    %{
      auto: @auto_label,
      awaiting_human: @awaiting_human_label,
      lifecycle_complete: @lifecycle_complete_label,
      non_converged: @non_converged_label,
      blocked: @blocked_label
    }
  end

  defp prepare_github_dispatch(issue, history) do
    cond do
      history.active? ->
        with :ok <- validate_active_issue(issue),
             :ok <- validate_opt_in(issue),
             {:ok, role} <- RoleRouter.role_for_issue(issue),
             :ok <- reconcile_active_projection(issue, history, role),
             {:ok, projected_issue} <- github_client().fetch_issue(issue.id) do
          {:ok,
           %{
             issue: projected_issue,
             history: history,
             handoff: dispatch_handoff(history),
             lifecycle_context: Lifecycle.lifecycle_context(history)
           }}
        else
          {:error, :symphony_auto_required} = error -> error
          {:error, reason} -> handle_invalid_state(issue, history, reason)
        end

      history.lifecycle_id == nil ->
        with :ok <- validate_active_issue(issue),
             :ok <- validate_opt_in(issue),
             {:ok, :pm} <- RoleRouter.role_for_issue(issue) do
          start_lifecycle(issue, history)
        else
          {:ok, role} -> handle_invalid_state(issue, history, {:non_pm_role_without_lifecycle, role})
          {:error, :symphony_auto_required} = error -> error
          {:error, reason} -> handle_invalid_state(issue, history, reason)
        end

      terminal_rerun?(issue, history, :pm) ->
        with :ok <- validate_active_issue(issue),
             {:ok, :pm} <- RoleRouter.role_for_issue(issue) do
          start_lifecycle(issue, history)
        else
          {:ok, role} -> handle_invalid_state(issue, history, {:terminal_rerun_requires_pm, role})
          {:error, reason} -> handle_invalid_state(issue, history, reason)
        end

      true ->
        with :ok <- repair_terminal_projection(issue, history) do
          {:skip, {:terminal_lifecycle, history.terminal}}
        end
    end
  end

  defp handle_invalid_state(issue, history, reason) do
    if has_label?(issue.labels, @auto_label) do
      block_invalid_state(issue, history, reason)
    else
      {:error, reason}
    end
  end

  defp block_invalid_state(issue, _history, reason) do
    diagnostic =
      "SYMPHONY lifecycle blocked: #{reason |> inspect() |> String.slice(0, 1_000)}"

    # The diagnostic is deliberately ordinary prose. It is not lifecycle
    # authority and therefore cannot manufacture a start or transition event.
    _ = github_client().append_issue_comment(issue.id, diagnostic)

    with :ok <- remove_auto_label(issue),
         :ok <- remove_present_role_labels(issue),
         :ok <- remove_state_labels(issue),
         {:ok, _} <- github_client().add_issue_label(issue.id, @blocked_label) do
      {:skip, {:blocked_lifecycle, reason}}
    else
      {:error, projection_reason} ->
        {:error, {:failed_to_block_lifecycle, reason, projection_reason}}
    end
  end

  defp append_pm_continuity_diagnostic(issue_id, reason) do
    diagnostic =
      "SYMPHONY PM thread continuity blocked: #{inspect(reason) |> String.slice(0, 1_000)}"

    case github_client().append_issue_comment(issue_id, diagnostic) do
      {:ok, _comment} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_opt_in(%Issue{labels: labels}) do
    if has_label?(labels, @auto_label), do: :ok, else: {:error, :symphony_auto_required}
  end

  defp validate_active_issue(%Issue{state: state}) when is_binary(state) do
    active_states = Config.settings!().tracker.active_states
    normalized_state = String.downcase(String.trim(state))

    if Enum.any?(active_states, &(String.downcase(String.trim(&1)) == normalized_state)) do
      :ok
    else
      {:error, {:issue_not_active, state}}
    end
  end

  defp validate_active_issue(_issue), do: {:error, :issue_not_active}

  defp start_lifecycle(issue, history) do
    if history.active? do
      {:error, :active_lifecycle_cannot_restart}
    else
      lifecycle_id = new_lifecycle_id()
      event = LifecycleHistory.start_event(lifecycle_id)
      body = LifecycleHistory.render(event)

      with {:ok, _comment} <- github_client().append_issue_comment(issue.id, body),
           {:ok, projected_issue} <- project_and_verify(issue, %{kind: "transition", to_role: :pm}),
           {:ok, comments} <- github_client().fetch_issue_comments(issue.id),
           {:ok, started_history} <- LifecycleHistory.from_comments(comments),
           {:ok, :pm} <- {:ok, started_history.current_role} do
        {:ok,
         %{
           issue: projected_issue,
           history: started_history,
           handoff: dispatch_handoff(started_history),
           lifecycle_context: Lifecycle.lifecycle_context(started_history)
         }}
      else
        {:ok, role} -> {:error, {:lifecycle_started_with_unexpected_role, role}}
        error -> error
      end
    end
  end

  defp terminal_rerun?(issue, history, :pm) do
    not history.active? and has_label?(issue.labels, @auto_label) and
      history.terminal in ["lifecycle_complete", "non_converged", "awaiting-human", "blocked"]
  end

  defp validate_commit_preconditions(issue, history, expected_role) do
    with :ok <- validate_active_issue(issue),
         :ok <- validate_opt_in(issue),
         {:ok, current_role} <- RoleRouter.role_for_issue(issue),
         {:ok, expected_role} <- canonical_role(expected_role),
         true <- history.active? or {:error, :no_active_lifecycle},
         true <- current_role == expected_role or {:error, :current_role_mismatch},
         true <- history.current_role == expected_role or {:error, :history_role_mismatch} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_expected_result(result, expected_role) do
    with {:ok, canonical_expected_role} <- canonical_role(expected_role),
         {:ok, validated} <- Lifecycle.validate_result(result),
         true <- validated["role"] == RoleProfiles.role_name(canonical_expected_role) do
      {:ok, validated}
    else
      false -> {:error, :role_result_role_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_prerequisite_commit(prerequisite_context, result) do
    report = Map.get(result, "prerequisite_resolution")
    outcome = result["outcome"]

    with :ok <- validate_required_prerequisite(prerequisite_context, report),
         :ok <- validate_plan_ready_prerequisite(outcome, report),
         :ok <- validate_await_human_prerequisite(outcome, report) do
      validate_non_converged_prerequisite(outcome, report)
    end
  end

  defp validate_required_prerequisite(%{required?: true}, report) when not is_map(report),
    do: {:error, :missing_prerequisite_resolution_report}

  defp validate_required_prerequisite(_context, _report), do: :ok

  defp validate_plan_ready_prerequisite("plan_ready", report) when is_map(report) do
    if report["resolution_status"] == "resolved" do
      :ok
    else
      {:error, :plan_ready_has_unresolved_prerequisite}
    end
  end

  defp validate_plan_ready_prerequisite(_outcome, _report), do: :ok

  defp validate_await_human_prerequisite("await_human", report) when is_map(report) do
    if report["resolution_status"] == "external_prerequisite" and
         report["authority_status"] == "requires_external_action" do
      :ok
    else
      {:error, :await_human_requires_specific_external_prerequisite}
    end
  end

  defp validate_await_human_prerequisite(_outcome, _report), do: :ok

  defp validate_non_converged_prerequisite("non_converged", report) do
    if Lifecycle.prerequisite_resolution_complete?(report) do
      :ok
    else
      {:error, :non_converged_requires_complete_prerequisite_resolution}
    end
  end

  defp validate_non_converged_prerequisite(_outcome, _report), do: :ok

  defp transition_for_commit(history, result) do
    prerequisite_context = Lifecycle.prerequisite_context(history)

    context = %{
      pm_phase: history.pm_phase || :initial,
      completed_working_round?: history.completed_working_round?,
      preceding_adversary_findings: history.preceding_adversary_findings,
      findings: result["findings"],
      prerequisite_resolution: result["prerequisite_resolution"]
    }

    with :ok <- validate_prerequisite_commit(prerequisite_context, result),
         {:ok, transition} <- Lifecycle.transition_for_result(result, context),
         {:ok, position} <- transition_position(history, result),
         {:ok, budget_transition} <- apply_budget(history, result, transition, position) do
      {:ok,
       Map.merge(budget_transition, %{
         result: result,
         round: position.round,
         planning_attempt: position.planning_attempt
       })}
    end
  end

  defp validate_evidence_reconciliation(history, %{"role" => "PM"} = result) do
    case validate_pm_escalation_basis(result) do
      :ok -> validate_pm_reconciliation(history, result)
      {:error, _reason} = error -> error
    end
  end

  defp validate_evidence_reconciliation(_history, _result), do: :ok

  defp validate_pm_reconciliation(history, result) do
    case reconciliation_projection(history, result) do
      nil ->
        validate_initial_pm_references(result)

      %{accepted_events: accepted_events, required_transition_ids: required_ids} = projection ->
        validate_projected_pm_reconciliation(result, projection, accepted_events, required_ids)
    end
  end

  defp validate_projected_pm_reconciliation(result, projection, accepted_events, required_ids) do
    with :ok <- validate_completed_round_evidence(projection),
         :ok <- validate_exact_reconciliation_ids(result["reconciliation"], required_ids) do
      validate_escalation_evidence(result, accepted_events)
    end
  end

  defp reconciliation_projection(history, result) do
    case LifecycleEvidence.project(history) do
      nil ->
        case replayed_pm_round(history, result) do
          nil -> nil
          round -> LifecycleEvidence.project_for_round(history, round)
        end

      projection ->
        projection
    end
  end

  defp replayed_pm_round(%{events: events}, %{"outcome" => outcome}) when is_list(events) do
    Enum.find_value(events, fn event ->
      if event["role"] == "PM" and event["outcome"] == outcome and is_integer(event["round"]) do
        event["round"]
      end
    end)
  end

  defp replayed_pm_round(_history, _result), do: nil

  defp validate_pm_escalation_basis(%{"outcome" => "await_human", "escalation_basis" => basis})
       when is_map(basis),
       do: :ok

  defp validate_pm_escalation_basis(%{"outcome" => "await_human"}),
    do: {:error, :missing_pm_escalation_basis}

  defp validate_pm_escalation_basis(_result), do: :ok

  defp validate_initial_pm_references(result) do
    reconciliation_ids = get_in(result, ["reconciliation", "considered_transition_ids"])
    supporting_ids = get_in(result, ["escalation_basis", "supporting_transition_ids"])

    cond do
      is_list(reconciliation_ids) and reconciliation_ids != [] ->
        {:error, {:invalid_reconciliation_reference, reconciliation_ids}}

      is_list(supporting_ids) and supporting_ids != [] ->
        {:error, {:invalid_escalation_reference, supporting_ids}}

      true ->
        :ok
    end
  end

  defp validate_completed_round_evidence(%{accepted_events: events}) do
    roles = Enum.map(events, & &1["role"])

    if "IMPLEMENTER" in roles and "ADVERSARY" in roles,
      do: :ok,
      else: {:error, :returning_pm_missing_completed_round_evidence}
  end

  defp validate_exact_reconciliation_ids(%{"considered_transition_ids" => ids}, required_ids)
       when is_list(ids) do
    if ids == required_ids do
      :ok
    else
      {:error, {:invalid_reconciliation_reference, %{expected: required_ids, received: ids}}}
    end
  end

  defp validate_exact_reconciliation_ids(_reconciliation, _required_ids),
    do: {:error, :missing_returning_pm_reconciliation}

  defp validate_escalation_evidence(%{"outcome" => "await_human", "escalation_basis" => basis}, events)
       when is_map(basis) do
    relevant_ids = MapSet.new(Enum.map(events, & &1["transition_id"]))
    supporting_ids = basis["supporting_transition_ids"]

    cond do
      supporting_ids == [] ->
        {:error, :missing_returning_pm_escalation_evidence}

      not Enum.all?(supporting_ids, &MapSet.member?(relevant_ids, &1)) ->
        {:error, {:invalid_escalation_reference, supporting_ids}}

      true ->
        :ok
    end
  end

  defp validate_escalation_evidence(%{"outcome" => "await_human"}, _events),
    do: {:error, :missing_returning_pm_escalation_evidence}

  defp validate_escalation_evidence(_result, _events), do: :ok

  defp transition_position(history, %{"role" => role_name, "outcome" => outcome}) do
    with {:ok, role} <- canonical_role(role_name) do
      case {role, outcome, history.pm_phase} do
        {:pm, "plan", :initial} -> {:ok, %{round: 1, planning_attempt: 1}}
        {:pm, "plan", :returning} -> {:ok, %{round: history.round + 1, planning_attempt: 1}}
        _ -> {:ok, %{round: history.round, planning_attempt: history.planning_attempt}}
      end
    end
  end

  defp apply_budget(history, %{"role" => role_name, "outcome" => "revise"} = result, transition, position) do
    with {:ok, :reviewer} <- canonical_role(role_name) do
      if history.planning_attempt >= 3 do
        {:ok,
         non_converged_transition(
           history,
           result,
           transition,
           position,
           planning_exhaustion_reason(history, result)
         )}
      else
        {:ok, Map.put(transition, :kind, "transition")}
      end
    end
  end

  defp apply_budget(_history, %{"outcome" => "non_converged"} = result, transition, position) do
    {:ok, non_converged_transition(%{}, result, transition, position, "prerequisite_no_feasible_authorized_path")}
  end

  defp apply_budget(history, %{"role" => "PM", "outcome" => "plan"} = result, transition, position) do
    if history.pm_phase == :returning and history.round >= 8 do
      {:ok, non_converged_transition(history, result, transition, position, "working_round_exhausted")}
    else
      {:ok, Map.put(transition, :kind, "transition")}
    end
  end

  defp apply_budget(_history, %{"outcome" => "await_human"}, transition, _position),
    do: {:ok, Map.put(transition, :kind, "escalation")}

  defp apply_budget(_history, %{"role" => "ARCHIVIST", "outcome" => "archive_complete"}, transition, _position),
    do: {:ok, Map.put(transition, :kind, "terminal")}

  defp apply_budget(_history, _result, transition, _position),
    do: {:ok, Map.put(transition, :kind, "transition")}

  defp planning_exhaustion_reason(history, result) do
    case Lifecycle.prerequisite_progress(history, result) do
      :unchanged -> "prerequisite_non_progress"
      _ -> "planning_attempt_exhausted"
    end
  end

  defp non_converged_transition(_history, result, transition, position, reason) do
    transition
    |> Map.put(:kind, "terminal")
    |> Map.put(:terminal, "NON_CONVERGED")
    |> Map.put(:terminal_reason, reason)
    |> Map.put(:to_role, :non_converged)
    |> Map.put(:round, position.round)
    |> Map.put(:planning_attempt, position.planning_attempt)
    |> Map.put(:result, result)
  end

  defp persist_transition(issue, history, transition) do
    event = event_payload(history, transition)
    transition_id = event["transition_id"]

    case Enum.find(history.events, &(&1["transition_id"] == transition_id)) do
      nil ->
        body = LifecycleHistory.render(event)

        with {:ok, _comment} <- github_client().append_issue_comment(issue.id, body) do
          {:ok, %{event: event, idempotent?: false}}
        end

      existing ->
        if existing == event do
          {:ok, %{event: event, idempotent?: true}}
        else
          {:error, {:conflicting_transition, transition_id}}
        end
    end
  end

  defp event_payload(history, transition) do
    result = transition.result
    role = result["role"]
    outcome = result["outcome"]
    to_role = transition.to_role

    payload = %{
      "schema" => LifecycleHistory.schema(),
      "kind" => transition.kind,
      "lifecycle_id" => history.lifecycle_id,
      "role_result_schema" => result["schema"],
      "transition_id" =>
        LifecycleHistory.transition_id(
          history.lifecycle_id,
          transition.round,
          transition.planning_attempt,
          elem(canonical_role(role), 1),
          outcome
        ),
      "role" => role,
      "from_role" => role,
      "outcome" => outcome,
      "to_role" => event_target(to_role),
      "round" => transition.round,
      "planning_attempt" => transition.planning_attempt,
      "summary" => result["summary"],
      "evidence" => result["evidence"],
      "findings" => result["findings"]
    }

    Map.merge(payload, %{
      "human_question" => Map.get(result, "human_question"),
      "prerequisite_resolution" => Map.get(result, "prerequisite_resolution"),
      "reconciliation" => Map.get(result, "reconciliation"),
      "escalation_basis" => Map.get(result, "escalation_basis"),
      "terminal_reason" => Map.get(transition, :terminal_reason)
    })
  end

  defp event_target(:await_human), do: "AWAITING_HUMAN"
  defp event_target(:lifecycle_complete), do: "LIFECYCLE_COMPLETE"
  defp event_target(:non_converged), do: "NON_CONVERGED"
  defp event_target(role), do: RoleProfiles.role_name(role)

  defp project_and_verify(issue, transition) do
    target =
      case transition.kind do
        "transition" -> {:role, transition.to_role}
        "escalation" -> {:awaiting_human, issue}
        "terminal" -> {:terminal, transition.to_role}
      end

    with :ok <- project_labels(issue, target),
         {:ok, verified} <- github_client().fetch_issue(issue.id),
         :ok <- verify_projection(verified, target) do
      {:ok, verified}
    end
  end

  defp project_labels(issue, {:role, role}) do
    with :ok <- remove_present_role_labels(issue),
         :ok <- remove_state_labels(issue),
         {:ok, _} <- github_client().add_issue_label(issue.id, RoleProfiles.role_label(role)) do
      :ok
    end
  end

  defp project_labels(issue, {:awaiting_human, _current_issue}) do
    with :ok <- remove_auto_label(issue),
         :ok <- remove_state_labels(issue),
         {:ok, _} <- github_client().add_issue_label(issue.id, @awaiting_human_label) do
      :ok
    end
  end

  defp project_labels(issue, {:terminal, terminal}) do
    state_label =
      case terminal do
        :lifecycle_complete -> @lifecycle_complete_label
        :non_converged -> @non_converged_label
        _ -> @blocked_label
      end

    with :ok <- remove_auto_label(issue),
         :ok <- remove_present_role_labels(issue),
         :ok <- remove_state_labels(issue),
         {:ok, _} <- github_client().add_issue_label(issue.id, state_label) do
      :ok
    end
  end

  defp remove_present_role_labels(issue) do
    issue.labels
    |> Enum.filter(&(RoleProfiles.role_for_label(&1) != []))
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case github_client().remove_issue_label(issue.id, label) do
        {:ok, _} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp remove_state_labels(issue) do
    issue.labels
    |> Enum.filter(&state_label?/1)
    |> Enum.reduce_while(:ok, fn label, :ok ->
      case github_client().remove_issue_label(issue.id, label) do
        {:ok, _} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp remove_auto_label(issue) do
    if has_label?(issue.labels, @auto_label) do
      case github_client().remove_issue_label(issue.id, @auto_label) do
        {:ok, _} -> :ok
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp verify_projection(issue, {:role, role}) do
    if has_label?(issue.labels, @auto_label) and
         RoleRouter.role_for_issue(issue) == {:ok, role} and
         not Enum.any?(issue.labels, &state_label?/1) do
      :ok
    else
      {:error, :lifecycle_role_projection_verification_failed}
    end
  end

  defp verify_projection(issue, {:awaiting_human, _}) do
    with false <- has_label?(issue.labels, @auto_label),
         true <- has_label?(issue.labels, @awaiting_human_label),
         {:ok, _role} <- RoleRouter.role_for_issue(issue) do
      :ok
    else
      _ -> {:error, :awaiting_human_projection_verification_failed}
    end
  end

  defp verify_projection(issue, {:terminal, terminal}) do
    expected =
      case terminal do
        :lifecycle_complete -> @lifecycle_complete_label
        :non_converged -> @non_converged_label
        _ -> @blocked_label
      end

    if not has_label?(issue.labels, @auto_label) and
         RoleRouter.role_for_issue(issue) == {:error, :missing_role_label} and
         has_label?(issue.labels, expected) do
      :ok
    else
      {:error, :terminal_projection_verification_failed}
    end
  end

  defp verify_pm_continuity_block(issue) do
    if not has_label?(issue.labels, @auto_label) and
         RoleRouter.role_for_issue(issue) == {:ok, :pm} and
         has_label?(issue.labels, @blocked_label) do
      :ok
    else
      {:error, :pm_continuity_block_projection_verification_failed}
    end
  end

  defp reconcile_active_projection(issue, history, role) do
    if active_projection_is_current?(issue, history, role) do
      :ok
    else
      reconcile_active_projection_repair(issue, history, role)
    end
  end

  defp active_projection_is_current?(issue, history, role) do
    has_label?(issue.labels, @auto_label) and
      role == history.current_role and
      not Enum.any?(issue.labels, &state_label?/1)
  end

  defp reconcile_active_projection_repair(issue, history, role) do
    cond do
      initial_pm_projection?(issue, history) -> repair_active_projection(issue, :pm)
      stale_previous_role?(issue, history) -> repair_active_projection(issue, history.current_role)
      no_role_label?(issue) -> repair_active_projection(issue, history.current_role)
      true -> {:error, {:lifecycle_label_corruption, role, history.current_role}}
    end
  end

  defp initial_pm_projection?(issue, history) do
    has_label?(issue.labels, @auto_label) and
      history.current_role == :pm and
      length(history.events) == 1 and
      Enum.any?(history.events, &(&1["kind"] == "lifecycle_started")) and
      Enum.any?(issue.labels, &state_label?/1)
  end

  defp repair_active_projection(issue, role) do
    case project_and_verify(issue, %{kind: "transition", to_role: role}) do
      {:ok, _issue} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp stale_previous_role?(issue, history) do
    case last_transition(history) do
      %{"from_role" => from_role} ->
        RoleRouter.role_for_issue(issue) == role_from_name(from_role)

      _ ->
        false
    end
  end

  defp last_transition(%{events: events}) do
    Enum.find(Enum.reverse(events), &Map.has_key?(&1, "transition_id"))
  end

  defp no_role_label?(%Issue{labels: labels}),
    do: Enum.all?(labels, &(RoleProfiles.role_for_label(&1) == []))

  defp repair_terminal_projection(issue, history) do
    target =
      case history.terminal do
        "lifecycle_complete" -> :lifecycle_complete
        "non_converged" -> :non_converged
        "awaiting-human" -> :awaiting_human
        _ -> :blocked
      end

    if terminal_projection_is_current?(issue, target) do
      :ok
    else
      case target do
        :awaiting_human ->
          project_labels(issue, {:awaiting_human, issue})

        _ ->
          project_labels(issue, {:terminal, target})
      end
    end
  end

  defp terminal_projection_is_current?(issue, :awaiting_human) do
    has_label?(issue.labels, @awaiting_human_label) and
      not has_label?(issue.labels, @auto_label) and
      match?({:ok, _role}, RoleRouter.role_for_issue(issue)) and
      exactly_one_state_label?(issue.labels)
  end

  defp terminal_projection_is_current?(issue, terminal)
       when terminal in [:lifecycle_complete, :non_converged, :blocked] do
    expected =
      case terminal do
        :lifecycle_complete -> @lifecycle_complete_label
        :non_converged -> @non_converged_label
        :blocked -> @blocked_label
      end

    has_label?(issue.labels, expected) and
      not has_label?(issue.labels, @auto_label) and
      RoleRouter.role_for_issue(issue) == {:error, :missing_role_label} and
      exactly_one_state_label?(issue.labels)
  end

  defp exactly_one_state_label?(labels) when is_list(labels) do
    Enum.count(labels, &state_label?/1) == 1
  end

  defp exactly_one_state_label?(_labels), do: false

  defp projected_history_after(%{idempotent?: true}, history), do: {:ok, history}

  defp projected_history_after(%{event: event, idempotent?: false}, history) do
    LifecycleHistory.project(history.events ++ [event])
  end

  defp canonical_role(role) when role in @roles, do: {:ok, role}

  defp canonical_role(role) when is_binary(role) do
    case Enum.find(RoleProfiles.roles(), &(RoleProfiles.role_name(&1) == role)) do
      nil -> {:error, {:unknown_role, role}}
      canonical -> {:ok, canonical}
    end
  end

  defp canonical_role(role), do: {:error, {:unknown_role, role}}

  defp role_from_name(name) do
    case canonical_role(name) do
      {:ok, role} -> {:ok, role}
      error -> error
    end
  end

  defp github_tracker?, do: Config.settings!().tracker.kind == "github"

  defp github_client do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp has_label?(labels, expected) when is_list(labels) do
    Enum.any?(labels, fn label ->
      is_binary(label) and String.downcase(String.trim(label)) == expected
    end)
  end

  defp state_label?(label) when is_binary(label),
    do: String.starts_with?(String.downcase(String.trim(label)), @state_prefix)

  defp state_label?(_label), do: false

  defp new_lifecycle_id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
