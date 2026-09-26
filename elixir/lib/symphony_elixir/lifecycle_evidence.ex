defmodule SymphonyElixir.LifecycleEvidence do
  @moduledoc """
  Pure projections of accepted lifecycle evidence for host-owned handoffs.

  The input history is already reconstructed from the host-written lifecycle
  ledger. This module only selects original event maps and adds deterministic
  references; it does not summarize, interpret, or compare their free-text
  claims.
  """

  alias SymphonyElixir.LifecycleHistory

  @specialist_roles ["PLANNER", "REVIEWER", "IMPLEMENTER", "ADVERSARY"]

  @type projection :: %{
          lifecycle_id: String.t(),
          round: non_neg_integer(),
          accepted_events: [map()],
          required_transition_ids: [String.t()]
        }

  @spec returning_pm?(map()) :: boolean()
  def returning_pm?(%{
        active?: true,
        current_role: :pm,
        pm_phase: :returning,
        completed_working_round?: true
      }),
      do: true

  def returning_pm?(_history), do: false

  @spec project(map()) :: projection() | nil
  def project(%{events: events} = history) when is_list(events) do
    if returning_pm?(history) do
      project_for_round(history, history.round)
    end
  end

  def project(_history), do: nil

  @spec project_for_round(map(), non_neg_integer()) :: projection()
  def project_for_round(%{lifecycle_id: lifecycle_id, events: events}, round)
      when is_binary(lifecycle_id) and is_list(events) and is_integer(round) do
    accepted_events =
      Enum.filter(events, fn event ->
        event["lifecycle_id"] == lifecycle_id and
          event["round"] == round and
          event["role"] in @specialist_roles
      end)

    %{
      lifecycle_id: lifecycle_id,
      round: round,
      accepted_events: accepted_events,
      required_transition_ids: Enum.map(accepted_events, & &1["transition_id"])
    }
  end

  @spec revision_projection(map()) :: map() | nil
  def revision_projection(%{
        active?: true,
        current_role: :planner,
        lifecycle_id: lifecycle_id,
        round: round,
        planning_attempt: planning_attempt,
        events: events
      })
      when is_binary(lifecycle_id) and is_integer(round) and is_integer(planning_attempt) and
             is_list(events) do
    if planning_attempt > 0 do
      revision_projection_for_attempt(lifecycle_id, round, planning_attempt - 1, events)
    end
  end

  def revision_projection(_history), do: nil

  defp revision_projection_for_attempt(lifecycle_id, round, planning_attempt, events) do
    planner_id = LifecycleHistory.transition_id(lifecycle_id, round, planning_attempt, :planner, "plan_ready")
    reviewer_id = LifecycleHistory.transition_id(lifecycle_id, round, planning_attempt, :reviewer, "revise")
    planner = Enum.find(events, &(&1["transition_id"] == planner_id))
    reviewer = Enum.find(events, &(&1["transition_id"] == reviewer_id))
    revision_projection_for_pair(lifecycle_id, round, planning_attempt, planner, reviewer)
  end

  defp revision_projection_for_pair(lifecycle_id, round, planning_attempt, planner, reviewer) do
    if revision_pair?(lifecycle_id, round, planning_attempt, planner, reviewer) do
      %{
        lifecycle_id: lifecycle_id,
        round: round,
        planning_attempt: planning_attempt,
        rejected_planner: event_projection(planner),
        reviewer: event_projection(reviewer),
        reviewer_findings: finding_projection(reviewer)
      }
    end
  end

  defp revision_pair?(lifecycle_id, round, planning_attempt, planner, reviewer) do
    event_identity?(planner, lifecycle_id, round, planning_attempt, "PLANNER", "plan_ready", "REVIEWER") and
      (event_identity?(reviewer, lifecycle_id, round, planning_attempt, "REVIEWER", "revise", "PLANNER") or
         (event_identity?(reviewer, lifecycle_id, round, planning_attempt, "REVIEWER", "revise", "NON_CONVERGED") and
            reviewer["kind"] == "terminal" and reviewer["terminal_reason"] == "planning_attempt_exhausted"))
  end

  defp event_identity?(event, lifecycle_id, round, planning_attempt, role, outcome, to_role) do
    event["lifecycle_id"] == lifecycle_id and
      event["round"] == round and
      event["planning_attempt"] == planning_attempt and
      event["role"] == role and
      event["from_role"] == role and
      event["outcome"] == outcome and
      event["to_role"] == to_role and
      is_binary(event["transition_id"])
  end

  defp event_projection(event) do
    Map.take(event, [
      "transition_id",
      "role",
      "from_role",
      "outcome",
      "summary",
      "evidence",
      "findings",
      "round",
      "planning_attempt"
    ])
  end

  defp finding_projection(%{"transition_id" => reviewer_transition_id, "findings" => findings})
       when is_binary(reviewer_transition_id) and is_list(findings) do
    Enum.with_index(findings)
    |> Enum.map(fn {finding, index} ->
      %{
        "finding_ref" => finding_reference(reviewer_transition_id, index),
        "index" => index,
        "finding" => finding
      }
    end)
  end

  defp finding_projection(_reviewer), do: []

  defp finding_reference(reviewer_transition_id, index),
    do: "#{reviewer_transition_id}:finding:#{index}"
end
