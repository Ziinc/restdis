defmodule SupaCacherServer.Commands.PgrstPolicy do
  alias SupaCacherCache.Key
  alias SupaCacherCache.QueryCache
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.Rewarm

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key | opts]) do
    case Key.decode(wire_key) do
      {:ok, key} ->
        parsed = parse_opts(opts)
        apply_policy(state, wire_key, key, parsed)

      :error ->
        {Encoder.error("ERR invalid cache key"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'PGRST.POLICY' command"), state}

  defp apply_policy(state, wire_key, key, parsed) do
    existing_policy = PolicyStore.get(state.tenant_id, wire_key)

    new_policy = %{
      rewarm_s: Map.get(parsed, :rewarm_s, existing_policy.rewarm_s),
      persist: Map.get(parsed, :persist, existing_policy.persist)
    }

    PolicyStore.put(state.tenant_id, wire_key, new_policy)
    Rewarm.policy_changed(state.tenant_id, wire_key, key, new_policy)

    persist_result =
      if new_policy.persist != existing_policy.persist do
        SupaCacherCache.set_persist(state.tenant_id, key, new_policy.persist)
      else
        :ok
      end

    case persist_result do
      {:error, :persist_cap} ->
        {Encoder.error("ERR persist cap reached"), state}

      _ ->
        if ttl_ms = parsed[:ttl_ms] do
          QueryCache.put(state.tenant_id, key, get_current_value(state.tenant_id, key), ttl_ms: ttl_ms)
        end

        {Encoder.simple_string("OK"), state}
    end
  end

  defp get_current_value(tenant_id, key) do
    case SupaCacherCache.peek(tenant_id, key) do
      {:ok, value} -> value
      :miss -> nil
    end
  end

  defp parse_opts(opts) do
    opts
    |> Enum.chunk_every(2)
    |> Enum.reduce(%{}, fn
      [k, v], acc when is_binary(k) ->
        case String.upcase(k) do
          "TTL" ->
            case Integer.parse(v) do
              {s, ""} -> Map.put(acc, :ttl_ms, s * 1000)
              _ -> acc
            end

          "REWARM" ->
            case Integer.parse(v) do
              {s, ""} -> Map.put(acc, :rewarm_s, s)
              _ -> acc
            end

          _ ->
            acc
        end

      [k], acc when is_binary(k) ->
        if String.upcase(k) == "PERSIST", do: Map.put(acc, :persist, true), else: acc

      _, acc ->
        acc
    end)
  end
end
