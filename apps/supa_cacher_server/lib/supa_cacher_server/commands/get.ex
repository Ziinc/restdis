defmodule SupaCacherServer.Commands.Get do
  @moduledoc """
  Handles the RESP `GET` command.
  """

  alias SupaCacherCache.Key
  alias SupaCacherServer.PolicyStore
  alias SupaCacherServer.RESP.Encoder
  alias SupaCacherServer.Rewarm

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
        {Encoder.error("ERR only PGRST.* keys are supported"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'get' command"), state}

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
