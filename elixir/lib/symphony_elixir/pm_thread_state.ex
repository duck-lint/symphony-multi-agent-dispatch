defmodule SymphonyElixir.PMThreadState do
  @moduledoc """
  Host-local reconnect metadata for task-scoped PM Codex threads.

  This is deliberately not lifecycle state. GitHub comments and labels remain
  the lifecycle authority; this file only binds a Codex thread to an issue and
  lifecycle so a later PM execution can reconnect to it.
  """

  alias SymphonyElixir.{Config, InstanceConfig}

  @schema "symphony.pm-thread/v1"
  @allowed_keys ["schema", "lifecycle_id", "thread_id"]
  @app_name "symphony"
  @state_subdirectory "pm_threads"

  @type record :: %{
          "schema" => String.t(),
          "lifecycle_id" => String.t(),
          "thread_id" => String.t()
        }

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec resolve(String.t(), String.t(), :initial | :returning) ::
          {:resume, String.t()} | {:new, term()} | {:error, term()}
  def resolve(issue_id, lifecycle_id, phase)
      when is_binary(issue_id) and is_binary(lifecycle_id) and phase in [:initial, :returning] do
    case load(issue_id) do
      :missing when phase == :initial -> {:new, :missing}
      :missing -> {:error, :pm_thread_state_missing}
      {:ok, %{"lifecycle_id" => ^lifecycle_id, "thread_id" => thread_id}} ->
        {:resume, thread_id}

      {:ok, %{"lifecycle_id" => old_lifecycle_id}} when phase == :initial ->
        {:new, {:stale_lifecycle, old_lifecycle_id}}

      {:ok, %{"lifecycle_id" => old_lifecycle_id}} ->
        {:error, {:pm_thread_lifecycle_mismatch, old_lifecycle_id, lifecycle_id}}

      {:error, reason} when phase == :initial ->
        {:new, {:replaceable_stale_state, reason}}

      {:error, reason} -> {:error, {:pm_thread_state_unusable, reason}}
    end
  end

  def resolve(_issue_id, _lifecycle_id, _phase),
    do: {:error, :invalid_pm_thread_binding}

  @spec load(String.t(), keyword()) :: {:ok, record()} | :missing | {:error, term()}
  def load(issue_id, opts \\ []) when is_binary(issue_id) do
    with {:ok, path} <- path_for_issue(issue_id, opts) do
      case File.read(path) do
        {:ok, content} -> decode_record(content, path)
        {:error, :enoent} -> :missing
        {:error, reason} -> {:error, {:pm_thread_state_read_failed, path, reason}}
      end
    end
  end

  def load(_issue_id, _opts), do: {:error, :invalid_pm_thread_issue_id}

  @spec put(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def put(issue_id, lifecycle_id, thread_id, opts \\ [])
      when is_binary(issue_id) and is_binary(lifecycle_id) and is_binary(thread_id) do
    with :ok <- validate_identifier(issue_id, :issue_id),
         :ok <- validate_identifier(lifecycle_id, :lifecycle_id),
         :ok <- validate_identifier(thread_id, :thread_id),
         {:ok, path} <- path_for_issue(issue_id, opts),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      record = %{
        "schema" => @schema,
        "lifecycle_id" => lifecycle_id,
        "thread_id" => thread_id
      }

      atomic_write(path, Jason.encode!(record))
    end
  end

  def put(_issue_id, _lifecycle_id, _thread_id, _opts),
    do: {:error, :invalid_pm_thread_record}

  @doc false
  @spec path_for_test(String.t()) :: {:ok, Path.t()} | {:error, term()}
  def path_for_test(issue_id), do: path_for_issue(issue_id, [])

  defp decode_record(content, path) do
    case Jason.decode(content) do
      {:ok, record} when is_map(record) ->
        case validate_record(record) do
          :ok -> {:ok, record}
          {:error, reason} -> {:error, {:malformed_pm_thread_state, path, reason}}
        end

      {:ok, _value} -> {:error, {:malformed_pm_thread_state, path, :not_a_map}}
      {:error, reason} -> {:error, {:malformed_pm_thread_state, path, {:json, reason}}}
    end
  end

  defp validate_record(record) do
    keys = Map.keys(record)
    missing = @allowed_keys -- keys
    unknown = keys -- @allowed_keys

    cond do
      missing != [] -> {:error, {:missing_fields, missing}}
      unknown != [] -> {:error, {:unknown_fields, unknown}}
      record["schema"] != @schema -> {:error, {:invalid_schema, record["schema"]}}
      true ->
        with :ok <- validate_identifier(record["lifecycle_id"], :lifecycle_id),
             :ok <- validate_identifier(record["thread_id"], :thread_id) do
          :ok
        end
    end
  end

  defp validate_identifier(value, _field) when is_binary(value) do
    if String.trim(value) != "" and not String.contains?(value, ["\n", "\r", <<0>>]) do
      :ok
    else
      {:error, :blank_or_unsafe_identifier}
    end
  end

  defp validate_identifier(_value, field), do: {:error, {:invalid_identifier, field}}

  defp path_for_issue(issue_id, opts) do
    with :ok <- validate_identifier(issue_id, :issue_id),
         {:ok, root} <- state_root(opts) do
      scope = scope_hash()
      issue_hash = digest(issue_id)
      {:ok, Path.join([root, scope, issue_hash <> ".json"])}
    end
  end

  defp state_root(opts) do
    configured =
      Keyword.get(opts, :state_root) ||
        Application.get_env(:symphony_elixir, :pm_thread_state_root)

    root =
      configured ||
        case :os.type() do
          {:win32, _} ->
            System.get_env("LOCALAPPDATA") ||
              System.get_env("APPDATA") ||
              Path.join(System.user_home!(), "AppData/Local")

          {:unix, :darwin} ->
            System.get_env("XDG_STATE_HOME") ||
              Path.join(System.user_home!(), "Library/Application Support")

          _ ->
            System.get_env("XDG_STATE_HOME") ||
              Path.join(System.user_home!(), ".local/state")
        end

    if is_binary(root) and String.trim(root) != "" do
      {:ok, Path.join(Path.expand(root), @app_name <> "/" <> @state_subdirectory)}
    else
      {:error, :invalid_pm_thread_state_root}
    end
  end

  defp scope_hash do
    tracker = Config.settings!().tracker
    repo = get_in(tracker.provider, ["repo"]) || ""

    identity = [
      InstanceConfig.instance_config_file_path() |> Path.expand(),
      tracker.kind || "",
      repo
    ]

    digest(Enum.join(identity, "\0"))
  end

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp atomic_write(path, content) do
    temporary_path = path <> ".tmp-" <> digest("#{path}:#{System.unique_integer([:positive])}")

    case File.write(temporary_path, content, [:binary]) do
      :ok ->
        case File.rename(temporary_path, path) do
          :ok -> :ok
          {:error, reason} ->
            _ = File.rm(temporary_path)
            {:error, {:pm_thread_state_replace_failed, path, reason}}
        end

      {:error, reason} ->
        _ = File.rm(temporary_path)
        {:error, {:pm_thread_state_write_failed, temporary_path, reason}}
    end
  end
end
