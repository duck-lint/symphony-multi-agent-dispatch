defmodule SymphonyElixir.Lifecycle do
  @moduledoc """
  Pure host-owned SYMPHONY role-result validation and legal transition model.

  This module has no tracker, persistence, budget, or thread side effects. Its
  context argument is intentionally explicit so later durable lifecycle state can
  be supplied without changing the role/result contract.
  """

  alias SymphonyElixir.RoleProfiles

  @schema "symphony.role-result/v1"
  @required_result_keys ~w(schema role outcome summary evidence findings)
  @allowed_result_keys ~w(schema role outcome summary evidence findings human_question)
  @finding_keys ~w(severity summary evidence)

  @type destination :: RoleProfiles.role() | :await_human | :lifecycle_complete
  @type pm_phase :: :initial | :returning

  @spec validate_result(map()) :: {:ok, map()} | {:error, term()}
  def validate_result(result) when is_map(result) do
    with :ok <- validate_result_keys(result),
         :ok <- validate_schema(Map.get(result, "schema")),
         {:ok, role} <- validate_result_role(Map.get(result, "role")),
         {:ok, outcome} <- validate_result_outcome(role, Map.get(result, "outcome")),
         :ok <- validate_summary(Map.get(result, "summary")),
         :ok <- validate_evidence(Map.get(result, "evidence")),
         :ok <- validate_findings(Map.get(result, "findings")),
         :ok <- validate_human_question(outcome, Map.get(result, "human_question")) do
      {:ok, result}
    end
  end

  def validate_result(_result), do: {:error, :role_result_not_a_map}

  @spec decode_and_validate_result(String.t(), RoleProfiles.role()) ::
          {:ok, map()} | {:error, term()}
  def decode_and_validate_result(text, expected_role) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:error, :missing_role_result_output}

      trimmed ->
        decode_result_json(trimmed, expected_role)
    end
  end

  def decode_and_validate_result(_text, _expected_role),
    do: {:error, :invalid_role_result_output}

  @spec transition(RoleProfiles.role(), String.t() | atom(), map()) ::
          {:ok, destination()} | {:error, term()}
  def transition(role, outcome, context \\ %{}) when is_map(context) do
    with {:ok, canonical_role} <- canonical_role(role),
         {:ok, canonical_outcome} <- validate_result_outcome(canonical_role, outcome_string(outcome)) do
      transition_for(canonical_role, canonical_outcome, context)
    end
  end

  @spec transition_for_result(map(), map()) :: {:ok, map()} | {:error, term()}
  def transition_for_result(result, context \\ %{}) when is_map(context) do
    with {:ok, validated_result} <- validate_result(result),
         {:ok, role} <- canonical_role(validated_result["role"]),
         {:ok, destination} <- transition(role, validated_result["outcome"], context) do
      {:ok,
       %{
         result: validated_result,
         from_role: role,
         outcome: validated_result["outcome"],
         to_role: destination
       }}
    end
  end

  @spec legal_outcomes(RoleProfiles.role()) :: [String.t()]
  def legal_outcomes(role), do: RoleProfiles.allowed_outcomes(role)

  @spec lifecycle_context(map()) :: map()
  def lifecycle_context(%{current_role: current_role} = state) do
    case canonical_role(current_role) do
      {:ok, role} ->
        predecessor = predecessor_role(state)
        transition_context = lifecycle_transition_context(state)

        %{
          current_role: RoleProfiles.role_name(role),
          lifecycle_position: lifecycle_position(role, state, predecessor),
          predecessor: role_name_or_nil(predecessor),
          object_received: object_received(role, state, predecessor),
          object_produced: object_produced(role),
          round: Map.get(state, :round),
          planning_attempt: Map.get(state, :planning_attempt),
          pm_phase: phase_name(Map.get(state, :pm_phase)),
          completed_working_round?: Map.get(state, :completed_working_round?, false),
          implementation_status: implementation_status(role, state),
          already_happened: already_happened(role, predecessor),
          not_yet_happened: not_yet_happened(role, predecessor),
          outcome_routes: outcome_routes(role, transition_context),
          temporal_interpretation: temporal_interpretation(role, predecessor)
        }

      {:error, _reason} ->
        %{}
    end
  end

  def lifecycle_context(_state), do: %{}

  defp transition_for(_role, "await_human", _context), do: {:ok, :await_human}

  defp transition_for(:pm, "plan", context) do
    case Map.get(context, :pm_phase, :initial) do
      phase when phase in [:initial, :returning] -> {:ok, :planner}
      phase -> {:error, {:invalid_pm_phase, phase}}
    end
  end

  defp transition_for(:pm, "converge", context) do
    cond do
      Map.get(context, :pm_phase, :initial) != :returning ->
        {:error, :initial_pm_cannot_converge}

      Map.get(context, :completed_working_round?, false) != true ->
        {:error, :pm_convergence_precondition_not_met}

      blocking_findings?(Map.get(context, :preceding_adversary_findings, [])) ->
        {:error, :blocking_adversary_findings}

      true ->
        {:ok, :archivist}
    end
  end

  defp transition_for(:planner, "plan_ready", _context), do: {:ok, :reviewer}
  defp transition_for(:reviewer, "revise", _context), do: {:ok, :planner}

  defp transition_for(:reviewer, "accept", context) do
    if blocking_findings?(Map.get(context, :findings, [])) do
      {:error, :reviewer_accept_has_blocking_findings}
    else
      {:ok, :implementer}
    end
  end

  defp transition_for(:implementer, "implementation_complete", _context), do: {:ok, :adversary}
  defp transition_for(:adversary, "review_complete", _context), do: {:ok, :pm}
  defp transition_for(:archivist, "archive_complete", _context), do: {:ok, :lifecycle_complete}

  defp validate_result_keys(result) do
    keys = Map.keys(result)
    missing = @required_result_keys -- keys
    unknown = keys -- @allowed_result_keys

    cond do
      unknown != [] -> {:error, {:unknown_role_result_fields, unknown}}
      missing != [] -> {:error, {:missing_role_result_fields, missing}}
      true -> :ok
    end
  end

  defp validate_schema(@schema), do: :ok
  defp validate_schema(schema), do: {:error, {:invalid_role_result_schema, schema}}

  defp validate_result_role(role) do
    case Enum.find(RoleProfiles.roles(), fn candidate -> RoleProfiles.role_name(candidate) == role end) do
      nil -> {:error, {:invalid_role_result_role, role}}
      canonical_role -> {:ok, canonical_role}
    end
  end

  defp validate_result_outcome(role, outcome) when is_binary(outcome) do
    if outcome in RoleProfiles.allowed_outcomes(role) do
      {:ok, outcome}
    else
      {:error, {:invalid_role_outcome, role, outcome}}
    end
  end

  defp validate_result_outcome(role, outcome), do: {:error, {:invalid_role_outcome, role, outcome}}

  defp decode_result_json(trimmed, expected_role) do
    case Jason.decode(trimmed) do
      {:ok, result} when is_map(result) ->
        with {:ok, validated_result} <- validate_result(result),
             :ok <- validate_expected_role(validated_result, expected_role) do
          {:ok, validated_result}
        end

      {:ok, _result} ->
        {:error, :role_result_not_a_map}

      {:error, reason} ->
        {:error, {:role_result_json_decode_error, reason}}
    end
  end

  defp validate_expected_role(result, expected_role) do
    with {:ok, canonical_expected_role} <- canonical_role(expected_role) do
      expected_name = RoleProfiles.role_name(canonical_expected_role)

      if result["role"] == expected_name do
        :ok
      else
        {:error, {:role_result_role_mismatch, expected_name, result["role"]}}
      end
    end
  end

  defp validate_summary(summary) when is_binary(summary) do
    cond do
      String.trim(summary) == "" ->
        {:error, :empty_role_result_summary}

      String.length(summary) > RoleProfiles.role_result_summary_max_length() ->
        {:error, :role_result_summary_too_long}

      true ->
        :ok
    end
  end

  defp validate_summary(_summary), do: {:error, :invalid_role_result_summary}

  defp lifecycle_transition_context(state) do
    %{
      pm_phase: Map.get(state, :pm_phase) || :initial,
      completed_working_round?: Map.get(state, :completed_working_round?, false),
      preceding_adversary_findings: Map.get(state, :preceding_adversary_findings, []),
      findings: []
    }
  end

  defp predecessor_role(%{events: events}) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      case canonical_role(Map.get(event, "from_role")) do
        {:ok, role} -> role
        {:error, _reason} -> nil
      end
    end)
  end

  defp predecessor_role(_state), do: nil

  defp role_name_or_nil(nil), do: nil
  defp role_name_or_nil(role), do: RoleProfiles.role_name(role)

  defp lifecycle_position(:pm, %{pm_phase: :returning}, _predecessor), do: "returning_pm"
  defp lifecycle_position(:pm, _state, _predecessor), do: "initial_pm"
  defp lifecycle_position(:planner, _state, :reviewer), do: "planning_correction"

  defp lifecycle_position(:planner, %{round: round}, _predecessor) when round > 1,
    do: "working_round_planning"

  defp lifecycle_position(:planner, _state, _predecessor), do: "initial_planning"
  defp lifecycle_position(:reviewer, _state, _predecessor), do: "pre_implementation_plan_review"
  defp lifecycle_position(:implementer, _state, _predecessor), do: "accepted_plan_execution"
  defp lifecycle_position(:adversary, _state, _predecessor), do: "post_implementation_falsification"
  defp lifecycle_position(:archivist, _state, _predecessor), do: "post_convergence_archival"

  defp object_received(:pm, %{pm_phase: :returning}, _predecessor), do: "completed working-round evidence, especially the Adversary result"
  defp object_received(:pm, _state, _predecessor), do: "issue, project authority, and current repository state"
  defp object_received(:planner, _state, :reviewer), do: "Reviewer correction request"
  defp object_received(:planner, _state, _predecessor), do: "PM planning direction"
  defp object_received(:reviewer, _state, _predecessor), do: "Planner's proposed implementation plan"
  defp object_received(:implementer, _state, _predecessor), do: "accepted Planner plan"
  defp object_received(:adversary, _state, _predecessor), do: "resulting implementation"
  defp object_received(:archivist, _state, _predecessor), do: "converged lifecycle history and result"

  defp object_produced(:pm), do: "bounded planning direction or convergence decision"
  defp object_produced(:planner), do: "proposed implementation plan"
  defp object_produced(:reviewer), do: "plan acceptance or revision result"
  defp object_produced(:implementer), do: "implemented project seam"
  defp object_produced(:adversary), do: "adversarial review result"
  defp object_produced(:archivist), do: "archival and continuity result"

  defp implementation_status(:pm, %{pm_phase: :returning}), do: "completed"
  defp implementation_status(:pm, _state), do: "not_started"
  defp implementation_status(role, _state) when role in [:planner, :reviewer], do: "not_started"
  defp implementation_status(:implementer, _state), do: "in_progress"
  defp implementation_status(role, _state) when role in [:adversary, :archivist], do: "completed"

  defp already_happened(:pm, nil), do: ["The lifecycle has started."]
  defp already_happened(:pm, :adversary), do: ["The current working round has completed implementation and adversarial review."]
  defp already_happened(:planner, :pm), do: ["PM produced planning direction for this planning attempt."]
  defp already_happened(:planner, :reviewer), do: ["Reviewer produced a correction request for this planning attempt."]
  defp already_happened(:reviewer, :planner), do: ["Planner produced the proposed implementation plan."]
  defp already_happened(:implementer, :reviewer), do: ["Reviewer accepted the proposed plan."]
  defp already_happened(:adversary, :implementer), do: ["Implementer completed the implementation result."]
  defp already_happened(:archivist, :pm), do: ["PM recorded a convergence decision."]
  defp already_happened(_role, _predecessor), do: []

  defp not_yet_happened(:pm, nil), do: ["Planning, implementation, and adversarial review have not occurred."]
  defp not_yet_happened(:pm, :adversary), do: ["The convergence decision for this completed working round has not occurred."]
  defp not_yet_happened(:planner, _predecessor), do: ["Implementation for this planning attempt has not run."]

  defp not_yet_happened(:reviewer, _predecessor),
    do: ["Implementer has not executed the proposed plan.", "Adversary has not reviewed the resulting implementation."]

  defp not_yet_happened(:implementer, _predecessor),
    do: ["Implementation completion and adversarial review have not occurred."]

  defp not_yet_happened(:adversary, _predecessor),
    do: ["PM has not integrated this adversarial result or decided convergence."]

  defp not_yet_happened(:archivist, _predecessor), do: ["Lifecycle archival completion has not occurred."]
  defp not_yet_happened(_role, _predecessor), do: []

  defp outcome_routes(role, transition_context) do
    RoleProfiles.allowed_outcomes(role)
    |> Enum.map(fn outcome ->
      available_now = transition(role, outcome, transition_context)
      route_probe = transition(role, outcome, route_probe_context(role, outcome, transition_context))

      %{
        outcome: outcome,
        destination: transition_destination(route_probe),
        available_now?: match?({:ok, _destination}, available_now),
        host_precondition: outcome_host_precondition(role, outcome)
      }
    end)
  end

  defp route_probe_context(:reviewer, "accept", context), do: Map.put(context, :findings, [])

  defp route_probe_context(:pm, "converge", context),
    do: Map.merge(context, %{completed_working_round?: true, preceding_adversary_findings: []})

  defp route_probe_context(_role, _outcome, context), do: context

  defp transition_destination({:ok, destination}), do: destination_name(destination)
  defp transition_destination({:error, _reason}), do: nil

  defp destination_name(:await_human), do: "AWAITING_HUMAN"
  defp destination_name(:lifecycle_complete), do: "LIFECYCLE_COMPLETE"

  defp destination_name(destination) when is_atom(destination) do
    if destination in RoleProfiles.roles(), do: RoleProfiles.role_name(destination), else: Atom.to_string(destination)
  end

  defp outcome_host_precondition(:pm, "converge"),
    do: "host requires a completed working round and no blocking preceding Adversary findings"

  defp outcome_host_precondition(:reviewer, "accept"),
    do: "host rejects acceptance when the result contains blocking findings"

  defp outcome_host_precondition(_role, _outcome), do: nil

  defp phase_name(nil), do: nil
  defp phase_name(phase), do: Atom.to_string(phase)

  defp temporal_interpretation(:pm, nil),
    do: "Initial PM establishes bounded planning direction; implementation has not begun."

  defp temporal_interpretation(:pm, :adversary),
    do: "Returning PM integrates completed working-round evidence and decides another plan or convergence."

  defp temporal_interpretation(:planner, :reviewer),
    do: "Produce a corrected proposed plan; implementation remains absent until a Reviewer accepts a plan."

  defp temporal_interpretation(:planner, _predecessor),
    do: "Produce a proposed plan; do not treat its proposed mutations as already applied."

  defp temporal_interpretation(:reviewer, _predecessor),
    do: "Evaluate the proposed plan before Implementer execution; absence of planned mutations is expected at this position."

  defp temporal_interpretation(:implementer, _predecessor),
    do: "Execute the accepted plan now; project changes are expected to begin at this position."

  defp temporal_interpretation(:adversary, _predecessor),
    do: "Falsify the resulting implementation after Implementer execution."

  defp temporal_interpretation(:archivist, _predecessor),
    do: "Record continuity after implementation and PM convergence have completed."

  defp validate_evidence(evidence) when is_list(evidence) do
    if Enum.all?(evidence, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_role_result_evidence}
    end
  end

  defp validate_evidence(_evidence), do: {:error, :invalid_role_result_evidence}

  defp validate_findings(findings) when is_list(findings) do
    Enum.reduce_while(findings, :ok, fn finding, :ok ->
      case validate_finding(finding) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_findings(_findings), do: {:error, :invalid_role_result_findings}

  defp validate_finding(finding) when is_map(finding) do
    with :ok <- validate_finding_keys(finding),
         :ok <- validate_finding_severity(finding),
         :ok <- validate_finding_summary(finding) do
      validate_finding_evidence(finding)
    end
  end

  defp validate_finding(_finding), do: {:error, :invalid_finding}

  defp validate_finding_keys(finding) do
    missing = @finding_keys -- Map.keys(finding)
    unknown = Map.keys(finding) -- @finding_keys

    cond do
      unknown != [] -> {:error, {:unknown_finding_fields, unknown}}
      missing != [] -> {:error, {:missing_finding_fields, missing}}
      true -> :ok
    end
  end

  defp validate_finding_severity(%{"severity" => severity}) when severity in ["blocking", "advisory"], do: :ok
  defp validate_finding_severity(_finding), do: {:error, :invalid_finding_severity}

  defp validate_finding_summary(%{"summary" => summary}) when is_binary(summary) do
    if String.trim(summary) == "", do: {:error, :invalid_finding_summary}, else: :ok
  end

  defp validate_finding_summary(_finding), do: {:error, :invalid_finding_summary}

  defp validate_finding_evidence(%{"evidence" => evidence}) when is_list(evidence) do
    if Enum.all?(evidence, &(is_binary(&1) and String.trim(&1) != "")),
      do: :ok,
      else: {:error, :invalid_finding_evidence}
  end

  defp validate_finding_evidence(_finding), do: {:error, :invalid_finding_evidence}

  defp validate_human_question("await_human", question)
       when is_binary(question) and byte_size(question) > 0,
       do: :ok

  defp validate_human_question("await_human", _question), do: {:error, :missing_human_question}
  defp validate_human_question(_outcome, nil), do: :ok
  defp validate_human_question(_outcome, _question), do: {:error, :unexpected_human_question}

  defp canonical_role(role) when role in [:pm, :planner, :reviewer, :implementer, :adversary, :archivist],
    do: {:ok, role}

  defp canonical_role(role) when is_binary(role) do
    case Enum.find(RoleProfiles.roles(), fn candidate -> RoleProfiles.role_name(candidate) == role end) do
      nil -> {:error, {:unknown_role, role}}
      canonical_role -> {:ok, canonical_role}
    end
  end

  defp canonical_role(role), do: {:error, {:unknown_role, role}}

  defp outcome_string(outcome) when is_atom(outcome), do: Atom.to_string(outcome)
  defp outcome_string(outcome), do: outcome

  defp blocking_findings?(findings) when is_list(findings) do
    Enum.any?(findings, fn
      finding when is_map(finding) ->
        Map.get(finding, "severity") == "blocking" or Map.get(finding, :severity) == :blocking

      _finding ->
        true
    end)
  end

  defp blocking_findings?(_findings), do: true
end
