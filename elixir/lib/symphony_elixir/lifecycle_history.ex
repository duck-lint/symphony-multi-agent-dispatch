defmodule SymphonyElixir.LifecycleHistory do
  @moduledoc """
  Pure parser and projection for host-written GitHub lifecycle comments.

  Ordinary GitHub comments are deliberately invisible here. A comment becomes
  lifecycle history only when it carries the exact host-owned marker and a
  valid JSON payload.
  """

  alias SymphonyElixir.{Lifecycle, RoleProfiles}

  @schema "symphony.lifecycle/v1"
  @event_kinds ["lifecycle_started", "transition", "terminal", "escalation", "blocked"]
  @roles [:pm, :planner, :reviewer, :implementer, :adversary, :archivist]
  @role_names Map.new(@roles, &{RoleProfiles.role_name(&1), &1})

  @type event :: map()
  @type state :: %{
          active?: boolean(),
          lifecycle_id: String.t() | nil,
          current_role: RoleProfiles.role() | nil,
          round: non_neg_integer(),
          planning_attempt: non_neg_integer(),
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
      body when is_binary(body) ->
        case Regex.run(
               ~r/\A<!--\s*symphony\.lifecycle\/v1\s*\r?\n(?<payload>\{.*\})\r?\n-->(?:\r?\n(?<summary>.*))?\z/s,
               body,
               capture: :all_names
             ) do
          [payload, summary] ->
            decode_event(payload, summary)

          nil ->
            if String.starts_with?(String.trim_leading(body), "<!-- symphony.lifecycle/v1") do
              {:error, :malformed_lifecycle_comment}
            else
              :ignore
            end
        end

      _ ->
        :ignore
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

  defp apply_new_event(state, event) do
    case apply_event(state, event) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  def project(_events), do: {:error, :lifecycle_events_not_a_list}

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

  @spec render(event(), String.t()) :: String.t()
  def render(event, summary) when is_map(event) and is_binary(summary) do
    "<!-- symphony.lifecycle/v1\n#{Jason.encode!(event)}\n-->\n#{String.trim(summary)}\n"
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
      nil -> :new
      existing ->
        if Map.delete(existing, "_human_summary") == Map.delete(event, "_human_summary"),
          do: :duplicate,
          else: {:conflict, lifecycle_id}
    end
  end

  defp duplicate_status(state, %{"transition_id" => transition_id} = event)
       when is_binary(transition_id) do
    case Enum.find(state.events, &(&1["transition_id"] == transition_id)) do
      nil -> :new
      existing ->
        if Map.delete(existing, "_human_summary") == Map.delete(event, "_human_summary"),
          do: :duplicate,
          else: {:conflict, transition_id}
    end
  end

  defp duplicate_status(_state, _event), do: :new

  defp comment_body(%{"body" => body}), do: body
  defp comment_body(%{body: body}), do: body
  defp comment_body(body) when is_binary(body), do: body
  defp comment_body(_comment), do: nil

  defp decode_event(payload, summary) do
    case Jason.decode(payload) do
      {:ok, event} when is_map(event) ->
        with :ok <- validate_event(event) do
          {:ok, Map.put(event, "_human_summary", String.trim(summary || ""))}
        end

      {:ok, _event} ->
        {:error, :lifecycle_event_not_a_map}

      {:error, reason} ->
        {:error, {:lifecycle_event_json_error, reason}}
    end
  end

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
    if Map.keys(event) -- ["schema", "kind", "lifecycle_id"] == [] do
      :ok
    else
      {:error, :invalid_lifecycle_started_fields}
    end
  end

  defp validate_kind_fields(%{"kind" => kind} = event) when kind in ["transition", "terminal", "escalation", "blocked"] do
    with :ok <- validate_common_event_fields(event),
         :ok <- validate_event_lists(event),
         :ok <- validate_event_numbers(event) do
      :ok
    end
  end

  defp validate_kind_fields(_event), do: {:error, :invalid_lifecycle_event}

  defp validate_common_event_fields(event) do
    required =
      case event["kind"] do
        "transition" -> ~w(transition_id from_role outcome to_role round planning_attempt summary evidence findings)
        "terminal" -> ~w(transition_id from_role outcome to_role round planning_attempt summary evidence findings)
        "escalation" -> ~w(transition_id from_role outcome to_role round planning_attempt summary evidence findings)
        "blocked" -> ~w(summary evidence findings)
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
    with :ok <- validate_string_list(event["evidence"], :evidence),
         :ok <- validate_findings(event["findings"]) do
      :ok
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

  defp valid_finding?(%{\"severity\" => severity, \"summary\" => summary, \"evidence\" => evidence})
       when severity in [\"blocking\", \"advisory\"] and is_binary(summary) and is_list(evidence) do
    String.trim(summary) != "" and Enum.all?(evidence, &(is_binary(&1) and String.trim(&1) != \"\"))
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
      false -> {:error, :lifecycle_from_role_mismatch}
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
             events: state.events ++ [event]
         }}
      else
        {:error, {:invalid_lifecycle_terminal, terminal}}
      end
    else
      false -> {:error, :lifecycle_from_role_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp apply_escalation_event(state, event) do
    with {:ok, from_role} <- role_from_name(event["from_role"]),
         true <- from_role == state.current_role or {:error, :lifecycle_from_role_mismatch},
         {:ok, :await_human} <- Lifecycle.transition(from_role, event["outcome"], transition_context(state, event)),
         :ok <- validate_event_position(state, from_role, event),
         :ok <- validate_transition_id(event, from_role),
         "AWAITING_HUMAN" <- event["to_role"] do
      {:ok,
       %{
         state
         | active?: false,
           terminal: "awaiting-human",
           transition_id: event["transition_id"],
           events: state.events ++ [event]
       }}
    else
      false -> {:error, :lifecycle_from_role_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_lifecycle_escalation}
    end
  end

  defp validate_event_position(state, :pm, %{"outcome" => "plan", "round" => round, "planning_attempt" => attempt}) do
    expected =
      case state.pm_phase do
        :initial -> %{round: 1, planning_attempt: 1}
        :returning -> %{round: state.round + 1, planning_attempt: 1}
        _ -> %{round: -1, planning_attempt: -1}
      end

    compare_position(expected, round, attempt)
  end

  defp validate_event_position(state, _role, %{"round" => round, "planning_attempt" => attempt}) do
    compare_position(%{round: state.round, planning_attempt: state.planning_attempt}, round, attempt)
  end

  defp compare_position(%{round: round, planning_attempt: attempt}, round, attempt), do: :ok
  defp compare_position(expected, round, attempt),
    do: {:error, {:invalid_lifecycle_event_position, expected, %{round: round, planning_attempt: attempt}}}

  defp validate_terminal_transition(_state, :archivist, %{"outcome" => "archive_complete", "to_role" => "LIFECYCLE_COMPLETE"}), do: :ok

  defp validate_terminal_transition(state, :reviewer, %{"outcome" => "revise", "to_role" => "NON_CONVERGED"}) do
    if state.planning_attempt >= 3, do: :ok, else: {:error, :premature_non_convergence}
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

  defp validate_target(target, destination) do
    expected =
      case destination do
        role when role in @roles -> RoleProfiles.role_name(role)
        :await_human -> "AWAITING_HUMAN"
        :lifecycle_complete -> "LIFECYCLE_COMPLETE"
      end

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
        pm_phase: :returning,
        transition_id: event["transition_id"]
    }
  end

  defp advance_state(state, :planner, "plan_ready", event),
    do: %{state | current_role: :reviewer, transition_id: event["transition_id"]}

  defp advance_state(state, :reviewer, "revise", event),
    do: %{state | current_role: :planner, planning_attempt: state.planning_attempt + 1, transition_id: event["transition_id"]}

  defp advance_state(state, :reviewer, "accept", event),
    do: %{state | current_role: :implementer, transition_id: event["transition_id"]}

  defp advance_state(state, :implementer, "implementation_complete", event),
    do: %{state | current_role: :adversary, transition_id: event["transition_id"]}

  defp advance_state(state, :adversary, "review_complete", event),
    do: %{state | current_role: :pm, pm_phase: :returning, completed_working_round?: true, preceding_adversary_findings: event["findings"], transition_id: event["transition_id"]}

  defp advance_state(state, _role, _outcome, event),
    do: %{state | transition_id: event["transition_id"]}

  defp role_from_name(name) do
    case Map.fetch(@role_names, name) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, {:invalid_lifecycle_role, name}}
    end
  end
end
