defmodule SymphonyElixir.HumanResponse do
  @moduledoc """
  Parses the one structured comment that can authorize continuation of an
  bounded lifecycle horizon.

  The comment body contains guidance, but authorization comes only from the
  authenticated GitHub comment metadata. This module intentionally ignores
  prose claims about authorship.
  """

  @schema "symphony.human-response/v1"

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec find([map()], String.t(), String.t(), String.t(), [pos_integer()]) ::
          :none | {:ok, map()} | {:error, term()}
  def find(comments, lifecycle_id, scope, target_transition_id, authorized_user_ids)
      when is_list(comments) and is_binary(lifecycle_id) and scope in ["epoch", "planning_cycle", "specialist"] and is_binary(target_transition_id) and
             is_list(authorized_user_ids) do
    find(comments, lifecycle_id, scope, target_transition_id, authorized_user_ids, [])
  end

  @spec find([map()], String.t(), String.t(), String.t(), [pos_integer()], [pos_integer()]) ::
          :none | {:ok, map()} | {:error, term()}
  def find(comments, lifecycle_id, scope, target_transition_id, authorized_user_ids, ignored_comment_ids)
      when is_list(comments) and is_binary(lifecycle_id) and scope in ["epoch", "planning_cycle", "specialist"] and is_binary(target_transition_id) and
             is_list(authorized_user_ids) and is_list(ignored_comment_ids) do
    parsed =
      comments
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {comment, index}, {:ok, matches} ->
        case parse(comment, index) do
          :ignore ->
            {:cont, {:ok, matches}}

          {:ok, response} ->
            {:cont, {:ok, collect_response(matches, response, lifecycle_id)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, responses} <- parsed,
         {:ok, current_responses} <-
           reject_stale_responses(responses, scope, target_transition_id, ignored_comment_ids) do
      select_authorized_response({:ok, current_responses}, authorized_user_ids)
    else
      {:error, _reason} = error -> error
    end
  end

  @spec parse(map(), non_neg_integer()) :: :ignore | {:ok, map()} | {:error, term()}
  def parse(comment, index) when is_map(comment) and is_integer(index) do
    body = Map.get(comment, "body") || Map.get(comment, :body)

    case body do
      body when is_binary(body) -> parse_body(body, comment, index)
      _ -> :ignore
    end
  end

  def parse(_comment, _index), do: :ignore

  defp parse_body(body, comment, index) do
    case Regex.run(~r/\A<!-- symphony\.human-response\/v1\r?\n(?<payload>.+)\r?\n-->\r?\n?\z/s, body, capture: :all_names) do
      [payload] ->
        with {:ok, response} <- Jason.decode(payload),
             :ok <- validate_response(response),
             {:ok, provenance} <- provenance(comment, body, index) do
          {:ok,
           Map.merge(response, %{
             lifecycle_id: response["lifecycle_id"],
             target_transition_id: response["target_transition_id"],
             provenance: provenance
           })}
        else
          {:error, reason} -> {:error, {:invalid_human_response, reason}}
        end

      nil ->
        if String.contains?(body, "symphony.human-response/v1"),
          do: {:error, :malformed_human_response_comment},
          else: :ignore
    end
  end

  defp validate_response(response) when is_map(response) do
    with :ok <- validate_response_fields(response) do
      validate_authorized_actions(response["authorized_actions"])
    end
  end

  defp validate_response(_response), do: {:error, :human_response_not_a_map}

  defp validate_response_fields(response) do
    allowed = ~w(schema lifecycle_id scope target_transition_id decision guidance authorized_actions)

    cond do
      Map.keys(response) -- allowed != [] ->
        {:error, :unknown_human_response_fields}

      response["schema"] != @schema ->
        {:error, :invalid_human_response_schema}

      not non_empty_string?(response["lifecycle_id"]) ->
        {:error, :invalid_human_response_lifecycle_id}

      response["scope"] not in ["epoch", "planning_cycle", "specialist"] ->
        {:error, :invalid_human_response_scope}

      not non_empty_string?(response["target_transition_id"]) ->
        {:error, :invalid_human_response_target_id}

      response["decision"] != "continue" ->
        {:error, :unsupported_human_response_decision}

      not non_empty_string?(response["guidance"]) ->
        {:error, :invalid_human_response_guidance}

      true ->
        :ok
    end
  end

  defp validate_authorized_actions(actions) when is_list(actions) do
    if Enum.all?(actions, &non_empty_string?/1),
      do: :ok,
      else: {:error, :invalid_human_response_authorized_actions}
  end

  defp validate_authorized_actions(_actions), do: {:error, :invalid_human_response_authorized_actions}

  defp provenance(comment, body, index) do
    user = Map.get(comment, "user") || Map.get(comment, :user)
    comment_id = Map.get(comment, "id") || Map.get(comment, :id)
    created_at = Map.get(comment, "created_at") || Map.get(comment, :created_at)
    updated_at = Map.get(comment, "updated_at") || Map.get(comment, :updated_at)
    url = Map.get(comment, "html_url") || Map.get(comment, :html_url)

    with {:ok, author_id} <- author_id(user),
         :ok <- validate_provenance_fields(comment_id, created_at, updated_at, url) do
      {:ok,
       %{
         "comment_id" => comment_id,
         "author_id" => author_id,
         "author_login" => get_in(user, ["login"]) || get_in(user, [:login]),
         "timestamp" => created_at,
         "url" => url,
         "content_digest" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
         "comment_index" => index
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp author_id(%{"id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp author_id(%{id: id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp author_id(_user), do: {:error, :missing_human_response_author_id}

  defp validate_provenance_fields(comment_id, created_at, updated_at, url) do
    cond do
      not is_integer(comment_id) -> {:error, :missing_human_response_comment_id}
      not non_empty_string?(created_at) -> {:error, :missing_human_response_created_at}
      not non_empty_string?(updated_at) -> {:error, :missing_human_response_updated_at}
      created_at != updated_at -> {:error, :edited_human_response_not_authorization}
      not non_empty_string?(url) -> {:error, :missing_human_response_url}
      true -> :ok
    end
  end

  defp collect_response(matches, response, lifecycle_id) do
    if response.lifecycle_id == lifecycle_id, do: [response | matches], else: matches
  end

  defp select_authorized_response({:ok, []}, _authorized_user_ids), do: :none

  defp select_authorized_response({:ok, responses}, authorized_user_ids) do
    authorized = Enum.filter(responses, &(&1[:provenance]["author_id"] in authorized_user_ids))

    cond do
      authorized == [] -> {:error, :unauthorized_human_response}
      conflicting_responses?(authorized) -> {:error, :conflicting_human_responses}
      true -> {:ok, Enum.min_by(authorized, &{&1[:provenance]["comment_id"], &1[:provenance]["comment_index"]})}
    end
  end

  defp conflicting_responses?(responses) do
    responses
    |> Enum.map(&Map.take(&1, ["decision", "guidance", "authorized_actions"]))
    |> Enum.uniq()
    |> length() > 1
  end

  defp reject_stale_responses(responses, scope, target_transition_id, ignored_comment_ids) do
    {current, stale} =
      Enum.split_with(responses, &(&1["scope"] == scope and &1.target_transition_id == target_transition_id))

    unacknowledged_stale =
      Enum.reject(stale, &(&1[:provenance]["comment_id"] in ignored_comment_ids))

    if current == [] and unacknowledged_stale != [],
      do: {:error, :stale_human_response_target},
      else: {:ok, current}
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
