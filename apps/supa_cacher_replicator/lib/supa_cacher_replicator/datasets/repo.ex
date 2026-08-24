defmodule SupaCacherReplicator.Datasets.Repo do
  @moduledoc """
  Lists the replication-mode datasets configured in the control-plane database.
  """

  import Ecto.Query

  alias SupaCacherReplicator.Dataset
  alias SupaCacherRepo.TenantTableConfig

  @doc """
  Returns one dataset per table configured in replication mode.
  """
  @spec list_replicated() :: [Dataset.t()]
  def list_replicated do
    from(ttc in TenantTableConfig, where: ttc.mode == "replication")
    |> SupaCacherRepo.all()
    |> Enum.map(fn ttc ->
      Dataset.new(%{
        tenant_id: ttc.tenant_id,
        schema: ttc.schema,
        table_name: ttc.table_name,
        pk_column: ttc.pk_column,
        filter: ttc.filter
      })
    end)
  end
end
