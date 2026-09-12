defmodule SymphonyElixir.instance_config do
  @moduledoc """
  Loads instance_config configuration and prompt from instance_config.yml.
  """

  alias SymphonyElixir.instance_configStore

  @instance_config_file_name "instance_config.yml"

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
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_instance_config()} | {:error, term()}
  def current do
    case Process.whereis(instance_configStore) do
      pid when is_pid(pid) ->
        instance_configStore.current()

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
        parse(content)

      {:error, reason} ->
        {:error, {:missing_instance_config_file, path, reason}}
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :instance_config_front_matter_not_a_map} ->
        {:error, :instance_config_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:instance_config_parse_error, reason}}
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :instance_config_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(instance_configStore) do
      _ = instance_configStore.force_reload()
    end

    :ok
  end
end
