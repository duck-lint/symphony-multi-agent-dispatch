defmodule SymphonyElixir.LifecycleHistory do
  @moduledoc """
  Pure parser and projection for host-written GitHub lifecycle comments.

  Ordinary GitHub comments are deliberately invisible here. A comment becomes
  lifecycle history only when it is the exact visible JSON ledger emitted by
  `render/1` and contains a valid lifecycle event.
  """

  alias SymphonyElixir.{Lifecycle, LifecycleIntegrity, RoleProfiles}

  @schema "symphony.lifecycle/v1"
  @event_kinds [
    "lifecycle_started",
    "transition",
    "terminal",
    "escalation",
    "human_response_accepted",
    "planning_response_accepted",
    "specialist_response_accepted",
    "blocked"
  ]
  @roles [:pm, :planner, :reviewer, :implementer, :adversary, :archivist]
  @role_names Map.new(@roles, &{RoleProfiles.role_name(&1), &1})

  @type event :: map()
  @type state :: %{
          active?: boolean(),
          lifecycle_id: String.t() | nil,
          current_role: RoleProfiles.role() | nil,
          round: non_neg_integer(),
          planning_attempt: non_neg_integer(),
          planning_cycle: non_neg_integer(),
          planning_cycle_start_attempt: non_neg_integer(),
          planning_cycle_attempt: non_neg_integer(),
          epoch: non_neg_integer(),
          epoch_round: non_neg_integer(),
          epoch_start_round: non_neg_integer(),
          human_guidance: map() | nil,
          planning_guidance: map() | nil,
          specialist_guidance: map() | nil,
          pm_phase: :initial | :returning | nil,
          completed_working_round?: boolean(),
          preceding_adversary_findings: list(),
          terminal: String.t() | nil,
          transition_id: String.t() | nil,
          events: [event()]
        }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec parse_comments([term()]) :: {:ok, [event()]} | {:error, term()}
  def parse_comments(comments) when is_list(comments) do
    Enum.reduce_while(comments, {:ok, []}, fn comment, {:ok, events} ->
      case parse_comment(comment) do
        :ignore -> {:cont, {:ok, events}}
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  def parse_comments(_comments), do: {:error, :lifecycle_comments_not_a_list}

  @spec parse_comment(term()) :: :ignore | {:ok, event()} | {:error, term()}
  def parse_comment(comment) do
    case comment_body(comment) do
      body when is_binary(body) -> parse_comment_body(body)
      _ -> :ignore
    end
  end

  defp parse_comment_body(body) do
    case Regex.run(~r/\A```json\r?\n(?<payload>\{.*\})\r?\n```\r?\n?\z/s, body, capture: :all_names) do
      [payload] ->
        decode_event(payload)

      nil ->
        if String.starts_with?(String.trim_leading(body), "```json") or
             String.starts_with?(String.trim_leading(body), "<!-- symphony.lifecycle/v1") do
          {:error, :malformed_lifecycle_comment}
        else
          :ignore
        end
    end
  end

  @spec project([event()]) :: {:ok, state()} | {:error, term()}
  def project(events) when is_list(events) do
    Enum.reduce_while(events, {:ok, empty_state()}, fn event, {:ok, state} ->
      case duplicate_status(state, event) do
        :duplicate ->
          {:cont, {:ok, state}}

        {:conflict, transition_id} ->
          {:halt, {:error, {:conflicting_lifecycle_event, transition_id}}}

        :new ->
          apply_new_event(state, event)
      end
    end)
  end

  def project(_events), do: {:error, :lifecycle_events_not_a_list}

  defp apply_new_event(state, event) do
    case apply_event(state, event) do
      {:ok, next_state} -> {:cont, {:ok, next_state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec from_comments([term()]) :: {:ok, state()} | {:error, term()}
  def from_comments(comments) do
    with {:ok, events} <- parse_comments(comments), do: project(events)
  end

  @spec transition_id(String.t(), non_neg_integer(), non_neg_integer(), RoleProfiles.role(), String.t()) ::
          String.t()
  def transition_id(lifecycle_id, round, planning_attempt, role, outcome)
      when is_binary(lifecycle_id) and is_integer(round) and is_integer(planning_attempt) do
    "#{lifecycle_id}:r#{round}:p#{planning_attempt}:#{RoleProfiles.role_name(role)}:#{outcome}"
  end

  @spec specialist_transition_id(String.t(), non_neg_integer(), non_neg_integer(), RoleProfiles.role(), String.t(), pos_integer()) :: String.t()
  def specialist_transition_id(lifecycle_id, round, planning_attempt, role, outcome, ordinal)
      when is_binary(lifecycle_id) and is_integer(round) and is_integer(planning_attempt) and
             is_integer(ordinal) and ordinal > 0 do
    base = transition_id(lifecycle_id, round, planning_attempt, role, outcome)
    if ordinal == 1, do: base, else: "#{base}:q#{ordinal}"
  end

  @spec next_specialist_question_ordinal([event()], RoleProfiles.role(), non_neg_integer(), non_neg_integer()) :: pos_integer()
  def next_specialist_question_ordinal(events, role, round, planning_attempt)
      when is_list(events) and is_integer(round) and is_integer(planning_attempt) do
    role_name = RoleProfiles.role_name(role)

    count =
      Enum.count(events, fn event ->
        event["kind"] == "escalation" and
          event["role"] == role_name and
          event["outcome"] == "await_human" and
          event["round"] == round and
          event["planning_attempt"] == planning_attempt
      end)

    count + 1
  end

  @spec render(event()) :: String.t()
  def render(event) when is_map(event) do
    signed_event = LifecycleIntegrity.sign(event)
    "```json\n#{Jason.encode!(signed_event, pretty: true)}\n```\n"
  end

  @spec start_event(String.t()) :: event()
  def start_event(lifecycle_id) when is_binary(lifecycle_id) do
    %{
      "schema" => @schema,
      "kind" => "lifecycle_started",
      "lifecycle_id" => lifecycle_id
    }
  end

  defp empty_state do
    %{
      active?: false,
      lifecycle_id: nil,
      current_role: nil,
      round: 0,
      planning_attempt: 0,
      planning_cycle: 0,
      planning_cycle_start_attempt: 0,
      planning_cycle_attempt: 0,
      epoch: 0,
      epoch_round: 0,
      epoch_start_round: 1,
      human_guidance: nil,
      planning_guidance: nil,
      specialist_guidance: nil,
      pm_phase: nil,
      completed_working_round?: false,
      preceding_adversary_findings: [],
      terminal: nil,
      transition_id: nil,
      events: []
    }
  end

  defp duplicate_status(state, %{"kind" => "lifecycle_started", "lifecycle_id" => lifecycle_id} = event) do
    case Enum.find(state.events, &(&1["kind"] == "lifecycle_started" and &1["lifecycle_id"] == lifecycle_id)) do
      nil ->
        :new

      existing ->
        if existing == event, do: :duplicate, else: {:conflict, lifecycle_id}
    end
  end

  defp duplicate_status(state, %{"transition_id" => transition_id} = event)
       when is_binary(transition_id) do
    case Enum.find(state.events, &(&1["transition_id"] == transition_id)) do
      nil ->
        :new

      existing ->
        if existing == event, do: :duplicate, else: {:conflict, transition_id}
    end
  end

  defp duplicate_status(_state, _event), do: :new

  defp comment_body(%{"body" => body}), do: body
  defp comment_body(%{body: body}), do: body
  defp comment_body(body) when is_binary(body), do: body
  defp comment_body(_comment), do: nil

  @spec decode_event(String.t()) :: {:ok, event()} | {:error, term()}
  defp decode_event(payload) do
    case Jason.decode(payload) do
      {:ok, event} ->
        with :ok <- validate_event(event) do
          {:ok, event}
        end

      {:error, reason} ->
        {:error, {:lifecycle_event_json_error, reason}}
    end
  end

  @spec validate_event(map()) :: :ok | {:error, term()}
  defp validate_event(event) do
    with :ok <- require_string(event, "schema"),
         :ok <- require_string(event, "kind"),
         :ok <- require_string(event, "lifecycle_id"),
         :ok <- validate_schema(event["schema"]),
         :ok <- validate_kind(event["kind"]) do
      validate_kind_fields(event)
    end
  end

  defp require_string(event, key) do
    if is_binary(event[key]) and String.trim(event[key]) != "" do
      :ok
    else
      {:error, {:missing_or_invalid_lifecycle_field, key}}
    end
  end

  defp validate_schema(@schema), do: :ok
  defp validate_schema(schema), do: {:error, {:invalid_lifecycle_schema, schema}}

  defp validate_kind(kind) when kind in @event_kinds, do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_lifecycle_event_kind, kind}}

  defp validate_kind_fields(%{"kind" => "lifecycle_started"} = event) do
    if Map.keys(event) -- ["schema", "kind", "lifecycle_id", "integrity"] == [] do
      :ok
    else
      {:error, :invalid_lifecycle_started_fields}
    end
  end

  defp validate_kind_fields(%{"kind" => kind} = event) when kind in ["transition", "terminal", "escalation", "blocked"] do
    with :ok <- validate_common_event_fields(event),
         :ok <- validate_event_lists(event),
         :ok <- validate_event_numbers(event) do
      validate_event_role_result(event)
    end
  end

  defp validate_kind_fields(%{"kind" => "human_response_accepted"} = event) do
    required = ~w(transition_id boundary_transition_id epoch starting_round guidance)

    with :ok <- require_fields(event, required),
         :ok <- validate_transition_id_field(event["transition_id"]),
         :ok <- validate_transition_id_field(event["boundary_transition_id"]),
         :ok <- validate_non_negative_number(event["epoch"]),
         :ok <- validate_non_negative_number(event["starting_round"]) do
      validate_guidance(event["guidance"])
    end
  end

  defp validate_kind_fields(%{"kind" => "planning_response_accepted"} = event) do
    required = ~w(transition_id boundary_transition_id round planning_cycle starting_planning_attempt guidance)

    with :ok <- require_fields(event, required),
         :ok <- validate_transition_id_field(event["transition_id"]),
         :ok <- validate_transition_id_field(event["boundary_transition_id"]),
         :ok <- validate_non_negative_number(event["round"]),
         :ok <- validate_non_negative_number(event["planning_cycle"]),
         :ok <- validate_non_negative_number(event["starting_planning_attempt"]) do
      validate_guidance(event["guidance"])
    end
  end

  defp validate_kind_fields(%{"kind" => "specialist_response_accepted"} = event) do
    required = ~w(transition_id boundary_transition_id role round planning_attempt guidance)

    with :ok <- require_fields(event, required),
         :ok <- validate_transition_id_field(event["transition_id"]),
         :ok <- validate_transition_id_field(event["boundary_transition_id"]),
         :ok <- validate_non_negative_number(event["round"]),
         :ok <- validate_non_negative_number(event["planning_attempt"]),
         :ok <- validate_specialist_response_role(event["role"]) do
      validate_guidance(event["guidance"])
    end
  end

  defp validate_specialist_response_role(role)
       when role in ["PLANNER", "REVIEWER", "IMPLEMENTER", "ADVERSARY", "ARCHIVIST"],
       do: :ok

  defp validate_specialist_response_role(_role), do: {:error, :invalid_specialist_response_role}

  defp require_fields(event, fields) do
    Enum.reduce_while(fields, :ok, fn key, :ok ->
      if Map.has_key?(event, key), do: {:cont, :ok}, else: {:halt, {:missing_lifecycle_event_field, key}}
    end)
  end

  defp validate_transition_id_field(value) when is_binary(value) and value != "", do: :ok
  defp validate_transition_id_field(_value), do: {:error, :invalid_human_response_transition_id}

  defp validate_non_negative_number(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative_number(_value), do: {:error, :invalid_human_response_position}

  defp validate_guidance(%{"decision" => decision, "text" => text, "authorized_actions" => actions})
       when decision in ["continue"] and is_binary(text) and is_list(actions) do
    if String.trim(text) != "" and Enum.all?(actions, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_human_response_guidance}
    end
  end

  defp validate_guidance(_guidance), do: {:error, :invalid_human_response_guidance}

  defp validate_event_role_result(%{"kind" => "blocked"}), do: :ok

  defp validate_event_role_result(event) do
    if event["role"] == event["from_role"] do
      result = %{
        "schema" => event["role_result_schema"],
        "role" => event["role"],
        "outcome" => event["outcome"],
        "summary" => event["summary"],
        "evidence" => event["evidence"],
        "findings" => event["findings"],
        "human_question" => event["human_question"],
        "prerequisite_resolution" => Map.get(event, "prerequisite_resolution"),
        "reconciliation" => Map.get(event, "reconciliation"),
        "revision_reconciliation" => Map.get(event, "revision_reconciliation"),
        "escalation_basis" => Map.get(event, "escalation_basis"),
        "human_guidance_acknowledgment" => Map.get(event, "human_guidance_acknowledgment")
      }

      case Lifecycle.validate_result(result) do
        {:ok, _validated} -> validate_terminal_reason(event["terminal_reason"])
        {:error, reason} -> {:error, {:invalid_lifecycle_role_result, reason}}
      end
    else
      {:error, :lifecycle_role_mismatch}
    end
  end

  defp validate_terminal_reason(nil), do: :ok

  defp validate_terminal_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: {:error, :invalid_lifecycle_terminal_reason}, else: :ok
  end

  defp validate_terminal_reason(_reason), do: {:error, :invalid_lifecycle_terminal_reason}

  defp validate_common_event_fields(event) do
    required =
      case event["kind"] do
        kind when kind in ["transition", "terminal", "escalation"] ->
          ~w(transition_id role role_result_schema from_role outcome to_role round planning_attempt summary evidence findings human_question terminal_reason)

        "blocked" ->
          ~w(summary evidence findings)
      end

    Enum.reduce_while(required, :ok, fn key, :ok ->
      if Map.has_key?(event, key) do
        {:cont, :ok}
      else
        {:halt, {:missing_lifecycle_event_field, key}}
      end
    end)
  end

  defp validate_event_lists(event) do
    with :ok <- validate_string_list(event["evidence"], :evidence) do
      validate_findings(event["findings"])
    end
  end

  defp validate_string_list(value, _field) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_lifecycle_event_list}
    end
  end

  defp validate_string_list(_value, field), do: {:error, {:invalid_lifecycle_event_list, field}}

  defp validate_findings(findings) when is_list(findings) do
    if Enum.all?(findings, &valid_finding?/1) do
      :ok
    else
      {:error, :invalid_lifecycle_event_findings}
    end
  end

  defp validate_findings(_findings), do: {:error, :invalid_lifecycle_event_findings}

  defp valid_finding?(%{"severity" => severity, "summary" => summary, "evidence" => evidence})
       when severity in ["blocking", "advisory"] and is_binary(summary) and is_list(evidence) do
    String.trim(summary) != "" and Enum.all?(evidence, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_finding?(_finding), do: false

  defp validate_event_numbers(event) do
    if event["kind"] == "blocked" or
         (is_integer(event["round"]) and event["round"] >= 0 and
            is_integer(event["planning_attempt"]) and event["planning_attempt"] >= 0) do
      :ok
    else
      {:error, :invalid_lifecycle_event_position}
    end
  end

  defp apply_event(%{active?: false} = state, %{"kind" => "lifecycle_started"} = event) do
    {:ok,
     %{
       state
       | active?: true,
         lifecycle_id: event["lifecycle_id"],
         current_role: :pm,
         round: 0,
         planning_attempt: 0,
         pm_phase: :initial,
         completed_working_round?: false,
         preceding_adversary_findings: [],
         terminal: nil,
         transition_id: nil,
         events: [event]
     }}
  end

  defp apply_event(%{active?: true} = _state, %{"kind" => "lifecycle_started"}),
    do: {:error, :active_lifecycle_restarted}

  defp apply_event(
         %{terminal: "awaiting-human", lifecycle_id: lifecycle_id} = state,
         %{
           "kind" => "human_response_accepted",
           "lifecycle_id" => lifecycle_id
         } = event
       ),
       do: apply_human_response_event(state, event)

  defp apply_event(
         %{terminal: "awaiting-human", lifecycle_id: lifecycle_id} = state,
         %{
           "kind" => "specialist_response_accepted",
           "lifecycle_id" => lifecycle_id
         } = event
       ),
       do: apply_specialist_response_event(state, event)

  defp apply_event(
         %{terminal: "non_converged", lifecycle_id: lifecycle_id} = state,
         %{"kind" => "planning_response_accepted", "lifecycle_id" => lifecycle_id} = event
       ),
       do: apply_planning_response_event(state, event)

  defp apply_event(%{active?: false, lifecycle_id: lifecycle_id}, %{"lifecycle_id" => lifecycle_id}),
    do: {:error, :lifecycle_event_after_terminal}

  defp apply_event(%{lifecycle_id: nil}, _event), do: {:error, :lifecycle_event_without_start}

  defp apply_event(%{lifecycle_id: lifecycle_id} = state, %{"lifecycle_id" => lifecycle_id} = event) do
    case event["kind"] do
      "transition" -> apply_transition_event(state, event)
      "terminal" -> apply_terminal_event(state, event)
      "escalation" -> apply_escalation_event(state, event)
      "blocked" -> {:ok, %{state | active?: false, terminal: "blocked", events: state.events ++ [event]}}
      _ -> {:error, :invalid_lifecycle_event}
    end
  end

  defp apply_event(_state, _event), do: {:error, :lifecycle_id_mismatch}

  defp apply_transition_event(state, event) do
    with {:ok, from_role} <- role_from_name(event["from_role"]),
         true <- from_role == state.current_role or {:error, :lifecycle_from_role_mismatch},
         {:ok, transition} <- Lifecycle.transition(from_role, event["outcome"], transition_context(state, event)),
         :ok <- validate_event_position(state, from_role, event),
         :ok <- validate_transition_id(event, from_role),
         :ok <- validate_target(event["to_role"], transition) do
      next_state = advance_state(state, from_role, event["outcome"], event)
      {:ok, %{next_state | events: state.events ++ [event]}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_terminal_event(state, event) do
    with {:ok, from_role} <- role_from_name(event["from_role"]),
         true <- from_role == state.current_role or {:error, :lifecycle_from_role_mismatch},
         :ok <- validate_event_position(state, from_role, event),
         :ok <- validate_transition_id(event, from_role),
         :ok <- validate_terminal_transition(state, from_role, event) do
      terminal = event["to_role"]

      if terminal in ["LIFECYCLE_COMPLETE", "NON_CONVERGED"] do
        {:ok,
         %{
           state
           | active?: false,
             terminal: String.downcase(terminal),
             transition_id: event["transition_id"],
             specialist_guidance: nil,
             events: state.events ++ [event]
         }}
      else
        {:error, {:invalid_lifecycle_terminal, terminal}}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_escalation_event(state, event) do
    with {:ok, from_role} <- role_from_name(event["from_role"]),
         true <- from_role == state.current_role or {:error, :lifecycle_from_role_mismatch},
         {:ok, :await_human} <- Lifecycle.transition(from_role, event["outcome"], transition_context(state, event)),
         :ok <- validate_event_position(state, from_role, event),
         :ok <- validate_escalation_transition_id(state, event, from_role),
         "AWAITING_HUMAN" <- event["to_role"] do
      {:ok,
       %{
         state
         | active?: false,
           terminal: "awaiting-human",
           specialist_guidance: nil,
           transition_id: event["transition_id"],
           events: state.events ++ [event]
       }}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_lifecycle_escalation}
    end
  end

  defp apply_human_response_event(%{active?: false, terminal: "awaiting-human"} = state, event) do
    cond do
      event["boundary_transition_id"] != state.transition_id ->
        {:error, :stale_human_response_escalation}

      state.current_role != :pm ->
        {:error, :human_response_requires_pm_escalation}

      event["epoch"] != state.epoch + 1 ->
        {:error, :invalid_human_response_epoch}

      event["starting_round"] != state.round + 1 ->
        {:error, :invalid_human_response_starting_round}

      event["transition_id"] != "#{state.lifecycle_id}:epoch#{event["epoch"]}:human_response" ->
        {:error, :invalid_human_response_transition_id}

      true ->
        {:ok,
         %{
           state
           | active?: true,
             terminal: nil,
             current_role: :pm,
             pm_phase: state.pm_phase || :returning,
             epoch: event["epoch"],
             epoch_round: 0,
             epoch_start_round: event["starting_round"],
             human_guidance: Map.put(event["guidance"], "response_transition_id", event["transition_id"]),
             transition_id: event["transition_id"],
             events: state.events ++ [event]
         }}
    end
  end

  defp apply_specialist_response_event(%{active?: false, terminal: "awaiting-human"} = state, event) do
    with {:ok, role} <- role_from_name(event["role"]),
         true <-
           role in [:planner, :reviewer, :implementer, :adversary, :archivist] or
             {:error, :specialist_response_requires_specialist_role},
         true <- state.current_role == role or {:error, :specialist_response_role_mismatch},
         true <-
           event["boundary_transition_id"] == state.transition_id or
             {:error, :stale_specialist_response_escalation},
         true <-
           (event["round"] == state.round and event["planning_attempt"] == state.planning_attempt) or
             {:error, :invalid_specialist_response_position},
         true <- event["transition_id"] == "#{state.transition_id}:response" or {:error, :invalid_specialist_response_transition_id} do
      guidance =
        Map.merge(event["guidance"], %{
          "response_transition_id" => event["transition_id"],
          "boundary_transition_id" => event["boundary_transition_id"],
          "role" => event["role"],
          "continuation" => "specialist_await_human"
        })

      {:ok,
       %{
         state
         | active?: true,
           terminal: nil,
           current_role: role,
           specialist_guidance: guidance,
           transition_id: event["transition_id"],
           events: state.events ++ [event]
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_planning_response_event(%{active?: false} = state, event) do
    with :ok <- validate_planning_boundary(List.last(state.events)),
         :ok <- validate_planning_boundary_reference(state, event),
         :ok <- validate_planning_response_position(state, event),
         :ok <- validate_planning_response_id(state, event) do
      {:ok,
       %{
         state
         | active?: true,
           terminal: nil,
           current_role: :planner,
           planning_attempt: event["starting_planning_attempt"],
           planning_cycle: event["planning_cycle"],
           planning_cycle_start_attempt: event["starting_planning_attempt"],
           planning_cycle_attempt: 1,
           planning_guidance: Map.put(event["guidance"], "response_transition_id", event["transition_id"]),
           transition_id: event["transition_id"],
           events: state.events ++ [event]
       }}
    end
  end

  defp validate_planning_boundary(%{
         "kind" => "terminal",
         "role" => "REVIEWER",
         "outcome" => "revise",
         "to_role" => "NON_CONVERGED",
         "terminal_reason" => "planning_attempt_exhausted"
       }),
       do: :ok

  defp validate_planning_boundary(_boundary), do: {:error, :invalid_planning_response_boundary}

  defp validate_planning_boundary_reference(state, event) do
    if event["boundary_transition_id"] == state.transition_id,
      do: :ok,
      else: {:error, :stale_planning_response_boundary}
  end

  defp validate_planning_response_position(state, event) do
    if event["round"] == state.round and event["planning_cycle"] == state.planning_cycle + 1 and
         event["starting_planning_attempt"] == state.planning_attempt + 1,
       do: :ok,
       else: {:error, :invalid_planning_response_position}
  end

  defp validate_planning_response_id(state, event) do
    expected = "#{state.lifecycle_id}:r#{state.round}:cycle#{event["planning_cycle"]}:planning_response"
    if event["transition_id"] == expected, do: :ok, else: {:error, :invalid_planning_response_transition_id}
  end

  defp validate_event_position(state, :pm, %{"outcome" => "plan", "round" => round, "planning_attempt" => attempt}) do
    expected =
      case state.pm_phase do
        :initial -> %{round: 1, planning_attempt: 1}
        :returning -> %{round: state.round + 1, planning_attempt: 1}
      end

    compare_position(expected, round, attempt)
  end

  defp validate_event_position(state, _role, %{"round" => round, "planning_attempt" => attempt}) do
    compare_position(%{round: state.round, planning_attempt: state.planning_attempt}, round, attempt)
  end

  defp compare_position(%{round: round, planning_attempt: attempt}, round, attempt), do: :ok

  defp compare_position(expected, round, attempt),
    do: {:error, {:invalid_lifecycle_event_position, expected, %{round: round, planning_attempt: attempt}}}

  defp validate_terminal_transition(
         state,
         :pm,
         %{"outcome" => "plan", "to_role" => "NON_CONVERGED", "terminal_reason" => "working_round_exhausted"}
       ) do
    if state.epoch_round >= 8, do: :ok, else: {:error, :premature_non_convergence}
  end

  defp validate_terminal_transition(_state, :archivist, %{"outcome" => "archive_complete", "to_role" => "LIFECYCLE_COMPLETE"}), do: :ok

  defp validate_terminal_transition(_state, role, %{
         "outcome" => "non_converged",
         "to_role" => "NON_CONVERGED",
         "prerequisite_resolution" => report
       })
       when role in [:planner, :reviewer] do
    if Lifecycle.prerequisite_resolution_complete?(report),
      do: :ok,
      else: {:error, :incomplete_prerequisite_non_convergence}
  end

  defp validate_terminal_transition(state, :reviewer, %{"outcome" => "revise", "to_role" => "NON_CONVERGED"}) do
    if state.planning_cycle_attempt >= 3, do: :ok, else: {:error, :premature_non_convergence}
  end

  defp validate_terminal_transition(_state, _role, _event),
    do: {:error, :invalid_lifecycle_terminal_transition}

  defp validate_transition_id(event, role) do
    expected =
      transition_id(
        event["lifecycle_id"],
        event["round"],
        event["planning_attempt"],
        role,
        event["outcome"]
      )

    if event["transition_id"] == expected do
      :ok
    else
      {:error, {:invalid_transition_id, expected, event["transition_id"]}}
    end
  end

  defp validate_escalation_transition_id(state, event, role) do
    expected =
      if role in [:planner, :reviewer, :implementer, :adversary, :archivist] do
        ordinal = next_specialist_question_ordinal(state.events, role, event["round"], event["planning_attempt"])
        specialist_transition_id(event["lifecycle_id"], event["round"], event["planning_attempt"], role, event["outcome"], ordinal)
      else
        transition_id(event["lifecycle_id"], event["round"], event["planning_attempt"], role, event["outcome"])
      end

    if event["transition_id"] == expected,
      do: :ok,
      else: {:error, {:invalid_transition_id, expected, event["transition_id"]}}
  end

  defp validate_target(target, destination) when destination in @roles do
    expected = RoleProfiles.role_name(destination)
    if target == expected, do: :ok, else: {:error, {:invalid_lifecycle_target, expected, target}}
  end

  defp transition_context(state, event) do
    %{
      pm_phase: state.pm_phase || :initial,
      completed_working_round?: state.completed_working_round?,
      preceding_adversary_findings: state.preceding_adversary_findings,
      findings: event["findings"] || []
    }
  end

  defp advance_state(state, :pm, "plan", event) do
    %{
      state
      | active?: true,
        current_role: :planner,
        round: event["round"],
        planning_attempt: 1,
        planning_cycle: 1,
        planning_cycle_start_attempt: 1,
        planning_cycle_attempt: 1,
        planning_guidance: nil,
        epoch_round: state.epoch_round + 1,
        pm_phase: :returning,
        transition_id: event["transition_id"],
        specialist_guidance: nil
    }
  end

  defp advance_state(state, :pm, "converge", event),
    do: %{state | current_role: :archivist, specialist_guidance: nil, transition_id: event["transition_id"]}

  defp advance_state(state, :planner, "plan_ready", event),
    do: %{state | current_role: :reviewer, specialist_guidance: nil, transition_id: event["transition_id"]}

  defp advance_state(state, :reviewer, "revise", event),
    do: %{
      state
      | current_role: :planner,
        planning_attempt: state.planning_attempt + 1,
        planning_cycle_attempt: state.planning_cycle_attempt + 1,
        specialist_guidance: nil,
        transition_id: event["transition_id"]
    }

  defp advance_state(state, :reviewer, "accept", event),
    do: %{
      state
      | current_role: :implementer,
        planning_guidance: nil,
        specialist_guidance: nil,
        transition_id: event["transition_id"]
    }

  defp advance_state(state, :implementer, "implementation_complete", event),
    do: %{state | current_role: :adversary, specialist_guidance: nil, transition_id: event["transition_id"]}

  defp advance_state(state, :adversary, "review_complete", event) do
    Map.merge(state, %{
      current_role: :pm,
      pm_phase: :returning,
      completed_working_round?: true,
      preceding_adversary_findings: event["findings"],
      transition_id: event["transition_id"],
      specialist_guidance: nil
    })
  end

  defp role_from_name(name) do
    case Map.fetch(@role_names, name) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, {:invalid_lifecycle_role, name}}
    end
  end
end
