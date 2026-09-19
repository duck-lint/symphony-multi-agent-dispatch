defmodule SymphonyElixir.LifecycleEvidenceTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LifecycleEvidence, LifecycleHistory}

  test "projects original current-round specialist events in ledger order" do
    lifecycle_id = "normalize-5"

    events = [
      LifecycleHistory.start_event(lifecycle_id),
      transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1),
      transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1),
      transition_event(lifecycle_id, "REVIEWER", "accept", "IMPLEMENTER", 1, 1),
      issue_five_implementer_event(lifecycle_id),
      issue_five_adversary_event(lifecycle_id)
    ]

    assert {:ok, history} = LifecycleHistory.project(events)
    projection = LifecycleEvidence.project(history)

    assert projection.lifecycle_id == lifecycle_id
    assert projection.round == 1

    assert Enum.map(projection.accepted_events, & &1["role"]) == [
             "PLANNER",
             "REVIEWER",
             "IMPLEMENTER",
             "ADVERSARY"
           ]

    assert Enum.map(projection.accepted_events, & &1["transition_id"]) ==
             projection.required_transition_ids

    assert Enum.find(projection.accepted_events, &(&1["role"] == "IMPLEMENTER"))["evidence"] == [
             "TMPDIR=/tmp .venv/bin/pytest -q -s reportedly yielded 12 passed",
             "clean-wheel verification reportedly succeeded"
           ]

    assert Enum.find(projection.accepted_events, &(&1["role"] == "ADVERSARY"))["evidence"] == [
             "separate pytest invocation yielded six passed",
             "six temporary-directory setup errors occurred before affected assertions"
           ]
  end

  test "initial history has no returning-PM projection" do
    assert {:ok, history} = LifecycleHistory.project([LifecycleHistory.start_event("initial")])
    refute LifecycleEvidence.returning_pm?(history)
    assert LifecycleEvidence.project(history) == nil
    assert LifecycleEvidence.revision_projection(history) == nil
    assert LifecycleEvidence.project(:not_a_history) == nil
  end

  test "revision projection selects the exact rejected plan and triggering review" do
    lifecycle_id = "life-revision"
    reviewer = revision_event(lifecycle_id, "REVIEWER", "revise", "PLANNER", 1, 1)
    planner = revision_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1)
    planner = Map.merge(planner, %{"summary" => "Original plan", "evidence" => ["plan evidence"]})
    reviewer =
      Map.merge(reviewer, %{
        "summary" => "Require the exact command and independent console verification.",
        "evidence" => ["review evidence"],
        "findings" => [
          %{"severity" => "blocking", "summary" => "Exact command is missing.", "evidence" => ["task contract"]},
          %{"severity" => "advisory", "summary" => "Independent console verification is missing.", "evidence" => ["review trace"]}
        ]
      })

    history = %{
      active?: true,
      current_role: :planner,
      lifecycle_id: lifecycle_id,
      round: 1,
      planning_attempt: 2,
      events: [LifecycleHistory.start_event(lifecycle_id), planner, reviewer]
    }

    projection = LifecycleEvidence.revision_projection(history)

    assert projection.lifecycle_id == lifecycle_id
    assert projection.round == 1
    assert projection.planning_attempt == 1
    assert projection.rejected_planner["transition_id"] == planner["transition_id"]
    assert projection.rejected_planner["summary"] == "Original plan"
    assert projection.rejected_planner["evidence"] == ["plan evidence"]
    assert projection.reviewer["transition_id"] == reviewer["transition_id"]
    assert projection.reviewer["summary"] == reviewer["summary"]
    assert projection.reviewer["evidence"] == ["review evidence"]
    assert Enum.map(projection.reviewer_findings, & &1["index"]) == [0, 1]
    assert Enum.map(projection.reviewer_findings, & &1["finding"]) == reviewer["findings"]
    assert Enum.map(projection.reviewer_findings, & &1["finding_ref"]) == [
             "#{reviewer["transition_id"]}:finding:0",
             "#{reviewer["transition_id"]}:finding:1"
           ]
  end

  test "revision projection rejects cross-round, cross-attempt, and cross-lifecycle pairs" do
    base = revision_event("life-current", "PLANNER", "plan_ready", "REVIEWER", 1, 1)
    reviewer = revision_event("life-current", "REVIEWER", "revise", "PLANNER", 1, 1)

    history = fn events ->
      %{
        active?: true,
        current_role: :planner,
        lifecycle_id: "life-current",
        round: 1,
        planning_attempt: 2,
        events: events
      }
    end

    assert LifecycleEvidence.revision_projection(history.([base, Map.put(reviewer, "round", 2)])) == nil
    assert LifecycleEvidence.revision_projection(history.([Map.put(base, "planning_attempt", 2), reviewer])) == nil
    assert LifecycleEvidence.revision_projection(history.([base, Map.put(reviewer, "lifecycle_id", "other-life")])) == nil
  end

  test "round projection preserves only matching lifecycle specialist events" do
    history = %{
      lifecycle_id: "life-current",
      events: [
        %{"lifecycle_id" => "other-life", "round" => 1, "role" => "IMPLEMENTER"},
        %{"lifecycle_id" => "life-current", "round" => 2, "role" => "ADVERSARY"},
        %{"lifecycle_id" => "life-current", "round" => 1, "role" => "IMPLEMENTER"},
        %{"lifecycle_id" => "life-current", "round" => 1, "role" => "OTHER"}
      ]
    }

    projection = LifecycleEvidence.project_for_round(history, 1)
    assert Enum.map(projection.accepted_events, & &1["role"]) == ["IMPLEMENTER"]
    assert projection.required_transition_ids == [nil]
  end

  defp transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "transition",
      "lifecycle_id" => lifecycle_id,
      "role_result_schema" => "symphony.role-result/v1",
      "transition_id" =>
        LifecycleHistory.transition_id(
          lifecycle_id,
          round,
          planning_attempt,
          String.downcase(from_role) |> String.to_atom(),
          outcome
        ),
      "role" => from_role,
      "from_role" => from_role,
      "outcome" => outcome,
      "to_role" => to_role,
      "round" => round,
      "planning_attempt" => planning_attempt,
      "summary" => "bounded result",
      "evidence" => ["evidence"],
      "findings" => [],
      "human_question" => nil,
      "terminal_reason" => nil
    }
  end

  defp issue_five_implementer_event(lifecycle_id) do
    transition_event(lifecycle_id, "IMPLEMENTER", "implementation_complete", "ADVERSARY", 1, 1)
    |> Map.merge(%{
      "summary" => "Reported implementation verification completed.",
      "evidence" => [
        "TMPDIR=/tmp .venv/bin/pytest -q -s reportedly yielded 12 passed",
        "clean-wheel verification reportedly succeeded"
      ]
    })
  end

  defp issue_five_adversary_event(lifecycle_id) do
    transition_event(lifecycle_id, "ADVERSARY", "review_complete", "PM", 1, 1)
    |> Map.merge(%{
      "summary" => "Independent reproduction was incomplete because setup failed.",
      "evidence" => [
        "separate pytest invocation yielded six passed",
        "six temporary-directory setup errors occurred before affected assertions"
      ],
      "findings" => [
        %{
          "severity" => "advisory",
          "summary" => "The independent run did not establish complete acceptance.",
          "evidence" => ["The setup errors occurred before the affected assertions executed."]
        }
      ]
    })
  end

  defp revision_event(lifecycle_id, role, outcome, to_role, round, planning_attempt) do
    %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "transition",
      "lifecycle_id" => lifecycle_id,
      "role_result_schema" => "symphony.role-result/v1",
      "transition_id" =>
        LifecycleHistory.transition_id(
          lifecycle_id,
          round,
          planning_attempt,
          String.downcase(role) |> String.to_atom(),
          outcome
        ),
      "role" => role,
      "from_role" => role,
      "outcome" => outcome,
      "to_role" => to_role,
      "round" => round,
      "planning_attempt" => planning_attempt,
      "summary" => "bounded result",
      "evidence" => ["evidence"],
      "findings" => [],
      "human_question" => nil,
      "terminal_reason" => nil
    }
  end
end
