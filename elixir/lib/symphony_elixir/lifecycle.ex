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
  @max_summary_length 4_000

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
  defp transition_for(role, outcome, _context), do: {:error, {:illegal_transition, role, outcome}}

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
      String.trim(summary) == "" -> {:error, :empty_role_result_summary}
      String.length(summary) > @max_summary_length -> {:error, :role_result_summary_too_long}
      true -> :ok
    end
  end

  defp validate_summary(_summary), do: {:error, :invalid_role_result_summary}

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
    missing = @finding_keys -- Map.keys(finding)
    unknown = Map.keys(finding) -- @finding_keys

    cond do
      unknown != [] ->
        {:error, {:unknown_finding_fields, unknown}}

      missing != [] ->
        {:error, {:missing_finding_fields, missing}}

      finding["severity"] not in ["blocking", "advisory"] ->
        {:error, :invalid_finding_severity}

      not is_binary(finding["summary"]) or String.trim(finding["summary"]) == "" ->
        {:error, :invalid_finding_summary}

      not is_list(finding["evidence"]) or
          not Enum.all?(finding["evidence"], &(is_binary(&1) and String.trim(&1) != "")) ->
        {:error, :invalid_finding_evidence}

      true ->
        :ok
    end
  end

  defp validate_finding(_finding), do: {:error, :invalid_finding}

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
