defmodule SupaCacherServer.Commands.Get do
  @moduledoc """
  Handles the RESP `GET` command.
  """

  alias SupaCacherCache.Key
  alias SupaCacherReplicator.Dataset
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.Rewarm

  @doc """
  Replies with the cached value of `wire_key`, or a null bulk string on a miss.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Key.decode(wire_key) do
      {:ok, key} ->
        case SupaCacherCache.get(state.tenant_id, key) do
          {:ok, value} ->
            Rewarm.touch(state.tenant_id, wire_key, key)
            {Encoder.bulk_string(Jason.encode!(value)), state}

          :miss ->
            maybe_cold_read(state.tenant_id, wire_key)
            {Encoder.bulk_string(nil), state}
        end

      :error ->
        replicated_get(state, wire_key)
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'get' command"), state}

  defp replicated_get(state, wire_key) do
    case Dataset.parse_wire_key(wire_key) do
      {:ok, {table, pk}} ->
        case SupaCacherReplicator.get(state.tenant_id, table, pk) do
          {:ok, value} -> {Encoder.bulk_string(Jason.encode!(value)), state}
          :miss -> {Encoder.bulk_string(nil), state}
        end

      :error ->
        {Encoder.error("ERR only PGRST.* and <table>:<primary_key> keys are supported"), state}
    end
  end

  defp maybe_cold_read(tenant_id, wire_key) do
    policy = PolicyStore.get(tenant_id, wire_key)

    if not is_nil(policy.rewarm_s) do
      :telemetry.execute(
        [:supa_cacher_server, :rewarm, :cold_read],
        %{count: 1},
        %{tenant_id: tenant_id}
      )
    end
  end
end
