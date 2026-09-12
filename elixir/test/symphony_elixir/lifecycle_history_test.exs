defmodule SymphonyElixir.LifecycleHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.LifecycleHistory

  test "ordinary comments are ignored and lifecycle comments project accepted history" do
    events = [
      LifecycleHistory.start_event("life-1"),
      transition_event("life-1", "PM", "plan", "PLANNER", 1, 1)
    ]

    comments = [
      %{"body" => "A human comment with no machine marker."},
      %{"body" => LifecycleHistory.render(Enum.at(events, 0), "started")},
      %{"body" => LifecycleHistory.render(Enum.at(events, 1), "planned")}
    ]

    assert {:ok, history} = LifecycleHistory.from_comments(comments)
    assert history.lifecycle_id == "life-1"
    assert history.current_role == :planner
    assert history.round == 1
    assert history.planning_attempt == 1
    assert length(history.events) == 2
  end

  test "malformed marked comments fail instead of becoming inferred history" do
    assert {:error, :malformed_lifecycle_comment} =
             LifecycleHistory.parse_comments([
               %{"body" => "<!-- symphony.lifecycle/v1\nnot-json\n-->"}
             ])
  end

  test "transition ids use the durable lifecycle position" do
    assert LifecycleHistory.transition_id("life-1", 2, 3, :reviewer, "revise") ==
             "life-1:r2:p3:REVIEWER:revise"
  end

  test "identical durable events are idempotent and conflicting duplicates fail" do
    start = LifecycleHistory.start_event("life-1")
    transition = transition_event("life-1", "PM", "plan", "PLANNER", 1, 1)
    changed = %{transition | "summary" => "different material result"}

    assert {:ok, history} =
             LifecycleHistory.project([start, transition, transition])

    assert history.current_role == :planner
    assert length(history.events) == 2

    assert {:error, {:conflicting_lifecycle_event, "life-1:r1:p1:PM:plan"}} =
             LifecycleHistory.project([start, transition, changed])
  end

  test "history reconstructs planning attempts and completed working rounds" do
    start = LifecycleHistory.start_event("life-1")

    attempt_three = [
      transition_event("life-1", "PM", "plan", "PLANNER", 1, 1),
      transition_event("life-1", "PLANNER", "plan_ready", "REVIEWER", 1, 1),
      transition_event("life-1", "REVIEWER", "revise", "PLANNER", 1, 1),
      transition_event("life-1", "PLANNER", "plan_ready", "REVIEWER", 1, 2),
      transition_event("life-1", "REVIEWER", "revise", "PLANNER", 1, 2),
      transition_event("life-1", "PLANNER", "plan_ready", "REVIEWER", 1, 3),
      terminal_event("life-1", "REVIEWER", "revise", "NON_CONVERGED", 1, 3)
    ]

    assert {:ok, history} = LifecycleHistory.project([start | attempt_three])
    refute history.active?
    assert history.terminal == "non_converged"

    completed_round = [
      transition_event("life-2", "PM", "plan", "PLANNER", 1, 1),
      transition_event("life-2", "PLANNER", "plan_ready", "REVIEWER", 1, 1),
      transition_event("life-2", "REVIEWER", "accept", "IMPLEMENTER", 1, 1),
      transition_event("life-2", "IMPLEMENTER", "implementation_complete", "ADVERSARY", 1, 1),
      transition_event("life-2", "ADVERSARY", "review_complete", "PM", 1, 1),
      transition_event("life-2", "PM", "plan", "PLANNER", 2, 1)
    ]

    assert {:ok, history} =
             LifecycleHistory.project([LifecycleHistory.start_event("life-2") | completed_round])

    assert history.active?
    assert history.current_role == :planner
    assert history.round == 2
    assert history.planning_attempt == 1
    assert history.completed_working_round?
  end

  defp transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "transition",
      "lifecycle_id" => lifecycle_id,
      "transition_id" =>
        LifecycleHistory.transition_id(
          lifecycle_id,
          round,
          planning_attempt,
          String.downcase(from_role) |> String.to_atom(),
          outcome
        ),
      "from_role" => from_role,
      "outcome" => outcome,
      "to_role" => to_role,
      "round" => round,
      "planning_attempt" => planning_attempt,
      "summary" => "bounded result",
      "evidence" => ["evidence"],
      "findings" => []
    }
  end

  defp terminal_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt)
    |> Map.put("kind", "terminal")
  end
end
