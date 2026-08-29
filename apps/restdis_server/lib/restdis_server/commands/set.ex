defmodule RestdisServer.Commands.Set do
  @moduledoc """
  Handles the RESP `SET` command.

  `SET` writes a plain, user-managed key/value pair readable back via `GET`,
  `MGET`, `TTL`, `EXISTS` and removable via `DEL`. It supports the standard
  `SET key value [EX seconds]` form.

  Two key namespaces are reserved and rejected by `SET`, since they are
  populated automatically elsewhere:

    * `pgrst:*` wire keys are the canonical cache keys returned by
      `PGRST.QUERY` and updated via `PGRST.POLICY`. They represent cached
      PostgREST query responses, not manually authored values.
    * Any other key containing a colon is reserved for the
      `<table>:<primary_key>` replicated dataset address space (see
      `RestdisReplicator.Dataset` and `GET`), which is populated by WAL-driven
      table replication.
  """

  alias Restdis.Cache.Key
  alias Restdis.Cache.Router
  alias RestdisServer.RESP.Encoder

  @doc """
  Stores `value` under `wire_key`, optionally with a TTL via `EX <seconds>`.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, [wire_key, value | rest]) do
    case Key.decode(wire_key) do
      {:ok, %Key{scope: :raw} = key} ->
        with {:ok, opts} <- parse_opts(rest) do
          put(state, key, value, opts)
        else
          :error -> {Encoder.error("ERR syntax error"), state}
        end

      {:ok, %Key{}} ->
        {Encoder.error(
           "ERR pgrst:* keys are managed by PGRST.QUERY/PGRST.POLICY and cannot be set directly"
         ), state}

      :error ->
        {Encoder.error(
           "ERR SET only supports plain keys; pgrst:* and <table>:<primary_key> keys are reserved"
         ), state}
    end
  end

  def run(state, _), do: {Encoder.error("ERR wrong number of arguments for 'set' command"), state}

  defp put(state, key, value, opts) do
    case Router.put(state.tenant_id, key, value, opts) do
      :ok ->
        {Encoder.simple_string("OK"), state}

      {:error, :persist_cap} ->
        {Encoder.error("ERR persist cap reached for tenant"), state}

      {:error, :unreachable} ->
        {Encoder.error("ERR origin unavailable"), state}
    end
  end

  defp parse_opts([]), do: {:ok, []}

  defp parse_opts(["EX", seconds]) do
    case Integer.parse(seconds) do
      {n, ""} when n > 0 -> {:ok, [ttl_ms: n * 1000]}
      _ -> :error
    end
  end

  defp parse_opts(_), do: :error
end
