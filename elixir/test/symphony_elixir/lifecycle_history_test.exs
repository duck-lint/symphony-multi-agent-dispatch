defmodule SymphonyElixir.LifecycleHistoryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{LifecycleHistory, LifecycleIntegrity}

  test "planning continuation resets only the local attempt budget and preserves transition identity" do
    lifecycle_id = "cycle-ledger"
    start = LifecycleHistory.start_event(lifecycle_id)
    first = transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1)

    cycle_one =
      Enum.flat_map(1..3, fn attempt ->
        planner = transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, attempt)
        reviewer = transition_event(lifecycle_id, "REVIEWER", "revise", "PLANNER", 1, attempt)

        if attempt == 3 do
          [
            planner,
            reviewer
            |> Map.put("kind", "terminal")
            |> Map.put("to_role", "NON_CONVERGED")
            |> Map.put("terminal_reason", "planning_attempt_exhausted")
          ]
        else
          [planner, reviewer]
        end
      end)

    boundary = List.last(cycle_one)
    assert {:ok, exhausted} = LifecycleHistory.project([start, first] ++ cycle_one)
    assert {exhausted.planning_cycle, exhausted.planning_attempt, exhausted.planning_cycle_attempt} == {1, 3, 3}
    refute exhausted.active?

    response = %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "planning_response_accepted",
      "lifecycle_id" => lifecycle_id,
      "transition_id" => "#{lifecycle_id}:r1:cycle2:planning_response",
      "boundary_transition_id" => boundary["transition_id"],
      "round" => 1,
      "planning_cycle" => 2,
      "starting_planning_attempt" => 4,
      "guidance" => %{
        "decision" => "continue",
        "text" => "Correct the reviewed defect.",
        "authorized_actions" => [],
        "provenance" => %{"comment_id" => 77, "author_id" => 7001}
      }
    }

    assert {:error, :stale_planning_response_boundary} =
             LifecycleHistory.project(
               [start, first] ++
                 cycle_one ++
                 [Map.put(response, "boundary_transition_id", "old-boundary")]
             )

    alternative_boundary = Map.put(boundary, "terminal_reason", "prerequisite_non_progress")

    assert {:error, :invalid_planning_response_boundary} =
             LifecycleHistory.project([start, first] ++ Enum.drop(cycle_one, -1) ++ [alternative_boundary, response])

    assert {:ok, resumed} = LifecycleHistory.project([start, first] ++ cycle_one ++ [response])
    assert {resumed.round, resumed.epoch, resumed.epoch_round} == {1, 0, 1}
    assert {resumed.planning_cycle, resumed.planning_attempt, resumed.planning_cycle_attempt} == {2, 4, 1}
    assert resumed.current_role == :planner
    assert resumed.planning_guidance["response_transition_id"] == response["transition_id"]

    cycle_two =
      Enum.flat_map(4..6, fn attempt ->
        planner = transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, attempt)
        reviewer = transition_event(lifecycle_id, "REVIEWER", "revise", "PLANNER", 1, attempt)

        if attempt == 6 do
          [
            planner,
            reviewer
            |> Map.put("kind", "terminal")
            |> Map.put("to_role", "NON_CONVERGED")
            |> Map.put("terminal_reason", "planning_attempt_exhausted")
          ]
        else
          [planner, reviewer]
        end
      end)

    assert {:ok, second_exhaustion} =
             LifecycleHistory.project([start, first] ++ cycle_one ++ [response] ++ cycle_two)

    assert second_exhaustion.planning_cycle == 2
    assert second_exhaustion.planning_attempt == 6
    assert second_exhaustion.planning_cycle_attempt == 3

    assert length(Enum.uniq(Enum.map(second_exhaustion.events, & &1["transition_id"]))) ==
             length(second_exhaustion.events)
  end

  test "ordinary comments are ignored and lifecycle comments project accepted history" do
    events = [
      LifecycleHistory.start_event("life-1"),
      transition_event("life-1", "PM", "plan", "PLANNER", 1, 1)
    ]

    comments = [
      %{"body" => "A human comment with no machine marker."},
      %{"body" => LifecycleHistory.render(Enum.at(events, 0))},
      %{"body" => LifecycleHistory.render(Enum.at(events, 1))}
    ]

    assert {:ok, history} = LifecycleHistory.from_comments(comments)
    assert history.lifecycle_id == "life-1"
    assert history.current_role == :planner
    assert history.round == 1
    assert history.planning_attempt == 1
    assert length(history.events) == 2
  end

  test "the visible JSON ledger is the exact parser input and preserves the full result" do
    finding = %{"severity" => "blocking", "summary" => "needs a human decision", "evidence" => ["review note"]}

    event =
      transition_event("life-visible", "PM", "await_human", "AWAITING_HUMAN", 0, 0)
      |> Map.merge(%{
        "kind" => "escalation",
        "transition_id" => LifecycleHistory.transition_id("life-visible", 0, 0, :pm, "await_human"),
        "human_question" => "Which direction should the implementation take?",
        "findings" => [finding]
      })

    body = LifecycleHistory.render(event)

    refute body =~ "<!--"
    assert body =~ "```json"
    assert body =~ "\"human_question\": \"Which direction should the implementation take?\""
    assert body =~ "\"review note\""
    signed_event = LifecycleIntegrity.sign(event)
    assert {:ok, ^signed_event} = LifecycleHistory.parse_comment(body)
  end

  test "old hidden lifecycle comments fail instead of becoming inferred history" do
    assert {:error, :malformed_lifecycle_comment} =
             LifecycleHistory.parse_comments([
               %{"body" => "<!-- symphony.lifecycle/v1\nnot-json\n-->"}
             ])
  end

  test "parser and projection reject malformed input without inventing history" do
    assert {:error, :lifecycle_comments_not_a_list} = LifecycleHistory.parse_comments(:not_a_list)
    assert {:error, :lifecycle_events_not_a_list} = LifecycleHistory.project(:not_a_list)
    assert :ignore = LifecycleHistory.parse_comment(%{body: 12})
    assert :ignore = LifecycleHistory.parse_comment(:not_a_comment)

    start = LifecycleHistory.start_event("life-parser")
    comment = LifecycleHistory.render(start)

    signed_start = LifecycleIntegrity.sign(start)
    assert {:ok, ^signed_start} = LifecycleHistory.parse_comment(comment)
    assert {:ok, ^signed_start} = LifecycleHistory.parse_comment(%{body: comment})
    assert {:ok, ^signed_start} = LifecycleHistory.parse_comment(%{body: comment})
    assert {:error, :malformed_lifecycle_comment} = LifecycleHistory.parse_comment(%{body: comment <> " trailing"})

    hidden_comment = "<!-- symphony.lifecycle/v1\n#{Jason.encode!(start)}\n-->"
    assert {:error, :malformed_lifecycle_comment} = LifecycleHistory.parse_comment(hidden_comment)

    assert {:error, {:lifecycle_event_json_error, _}} =
             LifecycleHistory.parse_comment("```json\n{bad}\n```")

    assert {:error, :lifecycle_event_without_start} =
             LifecycleHistory.project([transition_event("life-parser", "PM", "plan", "PLANNER", 1, 1)])

    assert {:error, :lifecycle_id_mismatch} =
             LifecycleHistory.project([
               LifecycleHistory.start_event("life-parser"),
               transition_event("other-life", "PM", "plan", "PLANNER", 1, 1)
             ])

    assert {:error, :active_lifecycle_restarted} =
             LifecycleHistory.project([
               LifecycleHistory.start_event("life-parser"),
               LifecycleHistory.start_event("other-life")
             ])

    assert {:error, :invalid_lifecycle_event} =
             LifecycleHistory.project([
               LifecycleHistory.start_event("life-parser"),
               %{"schema" => LifecycleHistory.schema(), "kind" => "unknown", "lifecycle_id" => "life-parser"}
             ])
  end

  test "event validation covers kind-specific fields, lists, findings, and positions" do
    base = transition_event("life-validation", "PM", "plan", "PLANNER", 1, 1)

    assert {:error, {:invalid_lifecycle_schema, "wrong/v1"}} = parse_event(Map.put(base, "schema", "wrong/v1"))
    assert {:error, {:invalid_lifecycle_event_kind, "unknown"}} = parse_event(Map.put(base, "kind", "unknown"))
    assert {:error, {:invalid_lifecycle_event_list, :evidence}} = parse_event(Map.put(base, "evidence", :bad))
    assert {:error, :invalid_lifecycle_event_findings} = parse_event(Map.put(base, "findings", :bad))
    assert {:error, :invalid_lifecycle_event_findings} = parse_event(Map.put(base, "findings", [%{"bad" => true}]))
    assert {:error, :invalid_lifecycle_event_list} = parse_event(Map.put(base, "evidence", [""]))
    assert {:error, :invalid_lifecycle_event_position} = parse_event(Map.put(base, "round", -1))

    terminal = Map.merge(base, %{"kind" => "terminal", "to_role" => "NON_CONVERGED"})
    escalation = Map.merge(base, %{"kind" => "escalation", "to_role" => "AWAITING_HUMAN", "outcome" => "await_human", "human_question" => "What operator input is required?"})

    blocked =
      Map.take(base, ["schema", "kind", "lifecycle_id", "summary", "evidence", "findings"])
      |> Map.put("kind", "blocked")

    assert {:ok, _} = parse_event(terminal)
    assert {:ok, _} = parse_event(escalation)
    assert {:ok, _} = parse_event(blocked)

    finding = %{"severity" => "advisory", "summary" => "valid", "evidence" => ["observed"]}
    assert {:ok, _} = parse_event(Map.put(base, "findings", [finding]))
    assert {:error, :invalid_lifecycle_event_findings} = parse_event(Map.put(base, "findings", [Map.put(finding, "summary", " ")]))

    assert {:error, {:invalid_lifecycle_role_result, :invalid_role_result_summary}} =
             parse_event(Map.put(base, "summary", 12))

    assert {:error, :invalid_lifecycle_terminal_reason} =
             parse_event(Map.put(terminal, "terminal_reason", " "))

    assert {:error, :invalid_lifecycle_terminal_reason} =
             parse_event(Map.put(terminal, "terminal_reason", 12))
  end

  test "projection handles blocked, escalated, terminal, and converged lifecycles" do
    lifecycle_id = "life-projection"
    start = LifecycleHistory.start_event(lifecycle_id)

    escalation =
      transition_event(lifecycle_id, "PM", "await_human", "AWAITING_HUMAN", 0, 0)
      |> Map.put("kind", "escalation")
      |> Map.put("transition_id", LifecycleHistory.transition_id(lifecycle_id, 0, 0, :pm, "await_human"))

    assert {:ok, %{active?: false, terminal: "awaiting-human"}} =
             LifecycleHistory.project([start, escalation])

    assert {:error, :lifecycle_from_role_mismatch} =
             LifecycleHistory.project([start, Map.put(escalation, "from_role", "PLANNER")])

    assert {:error, :invalid_lifecycle_escalation} =
             LifecycleHistory.project([start, Map.put(escalation, "outcome", "plan")])

    blocked =
      Map.take(escalation, ["schema", "lifecycle_id", "summary", "evidence", "findings"])
      |> Map.put("kind", "blocked")

    assert {:ok, %{active?: false, terminal: "blocked"}} =
             LifecycleHistory.project([start, blocked])

    assert {:error, {:invalid_lifecycle_role, "NOPE"}} =
             LifecycleHistory.project([start, Map.put(Map.put(escalation, "kind", "terminal"), "from_role", "NOPE")])

    assert {:error, :invalid_lifecycle_terminal_transition} =
             LifecycleHistory.project([
               start,
               Map.put(escalation, "kind", "terminal")
             ])

    wrong_position = transition_event(lifecycle_id, "PM", "plan", "PLANNER", 2, 1)

    assert {:error, {:invalid_lifecycle_event_position, _, _}} =
             LifecycleHistory.project([start, wrong_position])

    converge_events = [
      start,
      transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1),
      transition_event(lifecycle_id, "PLANNER", "plan_ready", "REVIEWER", 1, 1),
      transition_event(lifecycle_id, "REVIEWER", "accept", "IMPLEMENTER", 1, 1),
      transition_event(lifecycle_id, "IMPLEMENTER", "implementation_complete", "ADVERSARY", 1, 1),
      transition_event(lifecycle_id, "ADVERSARY", "review_complete", "PM", 1, 1),
      transition_event(lifecycle_id, "PM", "converge", "ARCHIVIST", 1, 1),
      terminal_event(lifecycle_id, "ARCHIVIST", "archive_complete", "LIFECYCLE_COMPLETE", 1, 1)
    ]

    assert {:ok, %{active?: false, terminal: "lifecycle_complete", current_role: :archivist}} =
             LifecycleHistory.project(converge_events)

    assert {:error, :lifecycle_event_after_terminal} =
             LifecycleHistory.project(converge_events ++ [transition_event(lifecycle_id, "PM", "plan", "PLANNER", 2, 1)])
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

  test "duplicate lifecycle starts conflict and invalid transitions halt projection" do
    start = LifecycleHistory.start_event("life-duplicate")

    assert {:error, {:conflicting_lifecycle_event, "life-duplicate"}} =
             LifecycleHistory.project([start, Map.put(start, "schema", "different")])

    assert {:error, {:invalid_lifecycle_role, "NOPE"}} =
             LifecycleHistory.project([
               start,
               Map.put(transition_event("life-duplicate", "PM", "plan", "PLANNER", 1, 1), "from_role", "NOPE")
             ])
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

  test "accepted human guidance starts an epoch without resetting global rounds" do
    lifecycle_id = "life-epoch"

    start = LifecycleHistory.start_event(lifecycle_id)

    escalation =
      transition_event(lifecycle_id, "PM", "await_human", "AWAITING_HUMAN", 0, 0)
      |> Map.merge(%{
        "kind" => "escalation",
        "transition_id" => LifecycleHistory.transition_id(lifecycle_id, 0, 0, :pm, "await_human"),
        "human_question" => "Which authorized direction should continue?",
        "escalation_basis" => %{
          "required_external_action" => "Supply a bounded decision.",
          "existing_authority_gap" => "The host cannot choose the product direction.",
          "supporting_transition_ids" => [LifecycleHistory.transition_id(lifecycle_id, 0, 0, :pm, "await_human")]
        }
      })

    accepted = %{
      "schema" => LifecycleHistory.schema(),
      "kind" => "human_response_accepted",
      "lifecycle_id" => lifecycle_id,
      "transition_id" => "#{lifecycle_id}:epoch1:human_response",
      "boundary_transition_id" => escalation["transition_id"],
      "epoch" => 1,
      "starting_round" => 1,
      "guidance" => %{
        "decision" => "continue",
        "text" => "Continue with the smallest supported correction.",
        "authorized_actions" => [],
        "provenance" => %{"comment_id" => 99, "author_id" => 7001}
      }
    }

    assert {:ok, resumed} = LifecycleHistory.project([start, escalation, accepted])
    assert resumed.active?
    assert resumed.current_role == :pm
    assert resumed.round == 0
    assert resumed.epoch == 1
    assert resumed.epoch_round == 0
    assert resumed.epoch_start_round == 1
    assert resumed.human_guidance["text"] == "Continue with the smallest supported correction."

    next_plan = transition_event(lifecycle_id, "PM", "plan", "PLANNER", 1, 1)
    assert {:ok, planned} = LifecycleHistory.project([start, escalation, accepted, next_plan])
    assert planned.round == 1
    assert planned.epoch_round == 1
    assert planned.epoch == 1

    assert {:error, :invalid_human_response_transition_id} =
             parse_event(Map.put(accepted, "transition_id", ""))

    assert {:error, :invalid_human_response_position} =
             parse_event(Map.put(accepted, "epoch", -1))

    assert {:error, :invalid_human_response_guidance} =
             parse_event(Map.put(accepted, "guidance", %{}))
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

  defp terminal_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt) do
    transition_event(lifecycle_id, from_role, outcome, to_role, round, planning_attempt)
    |> Map.put("kind", "terminal")
  end

  defp parse_event(event) do
    LifecycleHistory.parse_comment(LifecycleHistory.render(event))
  end
end
