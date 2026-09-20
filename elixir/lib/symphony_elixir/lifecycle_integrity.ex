defmodule SymphonyElixir.LifecycleIntegrity do
  @moduledoc """
  Authenticates host-written lifecycle ledger events.

  GitHub comment authorship is not sufficient here: the host and the configured
  human may use the same GitHub account. The instance-scoped secret therefore
  authenticates the event body without exposing host authority to role agents or
  project workspaces.
  """

  alias SymphonyElixir.Config

  @algorithm "hmac-sha256"

  @spec sign(map(), binary() | nil) :: map()
  def sign(event, secret \\ configured_secret()) when is_map(event) do
    case usable_secret(secret) do
      true ->
        payload = canonical_payload(event)
        signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
        Map.put(event, "integrity", %{"algorithm" => @algorithm, "signature" => signature})

      false ->
        event
    end
  end

  @spec verify(map(), binary() | nil) :: :ok | {:error, term()}
  def verify(event, secret \\ configured_secret()) when is_map(event) do
    cond do
      not usable_secret(secret) ->
        {:error, :lifecycle_integrity_unavailable}

      not match?(%{"algorithm" => @algorithm, "signature" => signature} when is_binary(signature), Map.get(event, "integrity")) ->
        {:error, :invalid_lifecycle_integrity}

      secure_compare(event["integrity"]["signature"], signature_for(event, secret)) ->
        :ok

      true ->
        {:error, :invalid_lifecycle_integrity}
    end
  end

  @spec verify_events([map()], binary() | nil) :: :ok | {:error, term()}
  def verify_events(events, secret \\ configured_secret()) when is_list(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case verify(event, secret) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:untrusted_lifecycle_event, reason}}}
      end
    end)
  end

  @spec configured_secret() :: binary() | nil
  def configured_secret do
    case Config.settings() do
      {:ok, %{lifecycle: %{integrity_secret: secret}}} -> secret
      _ -> nil
    end
  end

  defp signature_for(event, secret) do
    :crypto.mac(:hmac, :sha256, secret, canonical_payload(event))
    |> Base.encode16(case: :lower)
  end

  defp canonical_payload(event) do
    event
    |> Map.delete("integrity")
    |> canonicalize()
    |> Jason.encode!()
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested} -> {to_string(key), canonicalize(nested)} end)
    |> Map.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp usable_secret(secret), do: is_binary(secret) and byte_size(secret) > 0

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right), do: Plug.Crypto.secure_compare(left, right), else: false
  end
end
