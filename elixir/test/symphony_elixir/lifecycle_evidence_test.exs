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
end
