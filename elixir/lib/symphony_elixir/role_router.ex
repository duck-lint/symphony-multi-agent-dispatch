defmodule SymphonyElixir.RoleRouter do
  @moduledoc """
  Derives the current SYMPHONY role from host-controlled issue labels.
  """

  alias SymphonyElixir.RoleProfiles
  alias SymphonyElixir.Tracker.Issue

  @spec role_for_issue(Issue.t()) :: {:ok, RoleProfiles.role()} | {:error, term()}
  def role_for_issue(%Issue{labels: labels}), do: RoleProfiles.role_for_labels(labels)
  def role_for_issue(_issue), do: {:error, :missing_role_label}

  @spec profile_for_issue(Issue.t()) :: {:ok, map()} | {:error, term()}
  def profile_for_issue(%Issue{} = issue) do
    case role_for_issue(issue) do
      {:ok, role} -> RoleProfiles.profile(role)
      error -> error
    end
  end

  def profile_for_issue(_issue), do: {:error, :missing_role_label}
end
