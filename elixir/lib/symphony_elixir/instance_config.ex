defmodule SymphonyElixir.InstanceConfig do
  @moduledoc """
  Loads plain YAML runtime configuration from `.symphony/instance_config.yml`.

  The instance configuration contains no prompt body. Prompt construction belongs to
  the host-owned role-profile seam.
  """

  alias SymphonyElixir.InstanceConfigStore

  @instance_config_file_name Path.join(".symphony", "instance_config.yml")

  @spec instance_config_file_path() :: Path.t()
  def instance_config_file_path do
    Application.get_env(:symphony_elixir, :instance_config_file_path) ||
      Path.join(File.cwd!(), @instance_config_file_name)
  end

  @spec set_instance_config_file_path(Path.t()) :: :ok
  def set_instance_config_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :instance_config_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_instance_config_file_path() :: :ok
  def clear_instance_config_file_path do
    Application.delete_env(:symphony_elixir, :instance_config_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_instance_config :: %{
          config: map()
        }

  @spec current() :: {:ok, loaded_instance_config()} | {:error, term()}
  def current do
    case Process.whereis(InstanceConfigStore) do
      pid when is_pid(pid) ->
        InstanceConfigStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_instance_config()} | {:error, term()}
  def load do
    load(instance_config_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_instance_config()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_yaml(content)

      {:error, reason} ->
        {:error, {:missing_instance_config_file, path, reason}}
    end
  end

  defp parse_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, config} when is_map(config) -> {:ok, %{config: config}}
      {:ok, _config} -> {:error, :instance_config_not_a_map}
      {:error, reason} -> {:error, {:instance_config_parse_error, reason}}
    end
  end

  defp maybe_reload_store do
    if Process.whereis(InstanceConfigStore) do
      _ = InstanceConfigStore.force_reload()
    end

    :ok
  end
end
