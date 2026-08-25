defmodule RestdisReplicator.Dispatcher do
  @moduledoc """
  Entry point used by the buster context to dispatch refreshes for replication-mode tables.
  """

  alias RestdisReplicator.Dataset

  @doc """
  Applies a WAL change to the replicated dataset described by `config`.
  """
  @spec dispatch(map(), atom(), map()) :: :ok
  def dispatch(config, op, row) when op in [:insert, :update, :delete] do
    dataset = Dataset.new(config)

    case Dataset.pk_of(dataset, row) do
      nil ->
        :ok

      pk ->
        apply_op(dataset, op, pk)

        :telemetry.execute(
          [:restdis_replicator, :dispatch, :applied],
          %{count: 1},
          %{tenant_id: dataset.tenant_id, table: dataset.table, op: op}
        )

        :ok
    end
  end

  def dispatch(_config, _op, _row), do: :ok

  defp apply_op(dataset, :delete, pk), do: RestdisReplicator.delete_row(dataset, pk)
  defp apply_op(dataset, _op, pk), do: RestdisReplicator.refresh_row(dataset, pk)
end
