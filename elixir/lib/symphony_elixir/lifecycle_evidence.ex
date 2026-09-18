defmodule SymphonyElixir.LifecycleEvidence do
  @moduledoc """
  Pure projection of accepted specialist evidence for a returning PM.

  The input history is already reconstructed from the host-written lifecycle
  ledger. This module only selects original event maps; it does not summarize,
  interpret, or compare their free-text claims.
  """

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
      }), do: true

  def returning_pm?(_history), do: false

  @spec project(map()) :: projection() | nil
  def project(%{events: events} = history) when is_list(events) do
    if returning_pm?(history) do
      lifecycle_id = history.lifecycle_id
      round = history.round

      accepted_events =
        events
        |> Enum.filter(fn event ->
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
  end

  def project(_history), do: nil
end
