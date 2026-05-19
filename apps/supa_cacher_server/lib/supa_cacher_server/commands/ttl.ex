defmodule SupaCacherServer.Commands.Ttl do
  alias SupaCacherCache.Key
  alias SupaCacherServer.RESP.Encoder

  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key]) do
    case Key.decode(wire_key) do
      {:ok, key} ->
        case ets_lookup(state.tenant_id, key) do
          [{^key, _value, :infinity}] ->
            {Encoder.integer(-1), state}

          [{^key, _value, expires_at}] ->
            now = System.monotonic_time(:millisecond)
            remaining_s = max(0, div(expires_at - now, 1000))
            {Encoder.integer(remaining_s), state}

          [] ->
            {Encoder.integer(-2), state}
        end

      :error ->
        {Encoder.error("ERR only PGRST.* keys are supported"), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'ttl' command"), state}

  defp ets_lookup(tenant_id, key) do
    tid = :persistent_term.get({:sc_qc, tenant_id}, nil)
    if tid, do: :ets.lookup(tid, key), else: []
  end
end
