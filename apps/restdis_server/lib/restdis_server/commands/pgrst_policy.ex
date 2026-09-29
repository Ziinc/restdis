defmodule RestdisServer.Commands.PgrstPolicy do
  @moduledoc """
  Handles the RESP `PGRST.POLICY` command, updating TTL, rewarm and persist policy.
  """

  alias Restdis.Cache.Key
  alias Restdis.Cache.QueryCache
  alias RestdisServer.Commands.Support
  alias RestdisServer.PolicyStore
  alias RestdisServer.RESP.Encoder
  alias RestdisServer.Rewarm

  @doc """
  Applies TTL, rewarm and persist policy to a currently cached key; a key
  that is not cached replies `ERR no such key` and changes nothing.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key | opts]) do
    with {:ok, key} <- Key.decode(wire_key),
         {:ok, value} <- Restdis.Cache.peek(state.tenant_id, key) do
      apply_policy(state, {wire_key, key, value}, parse_opts(opts))
    else
      :error -> {Encoder.error("ERR invalid cache key"), state}
      :miss -> {Encoder.error("ERR no such key"), state}
    end
  end

  def run(state, _),
    do: {Encoder.error("ERR wrong number of arguments for 'PGRST.POLICY' command"), state}

  defp apply_policy(state, {wire_key, key, value}, parsed) do
    existing_policy = PolicyStore.get(state.tenant_id, wire_key)

    new_policy = %{
      rewarm_s: Map.get(parsed, :rewarm_s, existing_policy.rewarm_s),
      persist: Map.get(parsed, :persist, existing_policy.persist)
    }

    Rewarm.put_policy(state.tenant_id, wire_key, key, new_policy)

    persist_result =
      if new_policy.persist != existing_policy.persist do
        Restdis.Cache.set_persist(
          state.tenant_id,
          key,
          new_policy.persist,
          Support.persist_cap_opt(state.tenant_id)
        )
      else
        :ok
      end

    case persist_result do
      {:error, :persist_cap} ->
        {Encoder.error("ERR persist cap reached"), state}

      _ ->
        if ttl_ms = parsed[:ttl_ms] do
          QueryCache.put(state.tenant_id, key, value, name: Restdis.Cache, ttl_ms: ttl_ms)
        end

        {Encoder.simple_string("OK"), state}
    end
  end

  defp parse_opts(opts) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, &put_opt/2)
  end

  defp put_opt([k, v], acc) when is_binary(k) do
    case {String.upcase(k), Integer.parse(v)} do
      {"TTL", {s, ""}} -> Map.put(acc, :ttl_ms, s * 1000)
      {"REWARM", {s, ""}} -> Map.put(acc, :rewarm_s, s)
      _ -> acc
    end
  end

  defp put_opt([k], acc) when is_binary(k) do
    if String.upcase(k) == "PERSIST", do: Map.put(acc, :persist, true), else: acc
  end

  defp put_opt(_pair, acc), do: acc
end
