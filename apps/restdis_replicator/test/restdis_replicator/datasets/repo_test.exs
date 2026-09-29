defmodule RestdisReplicator.Datasets.RepoTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias RestdisReplicator.Dataset
  alias RestdisReplicator.Datasets.Repo, as: DatasetsRepo
  alias RestdisRepo.TenantTableConfig

  setup do
    owner = Sandbox.start_owner!(RestdisRepo, shared: true)

    # Stopping the owner leaves :manual mode; restore :auto for other apps' processes in the umbrella VM.
    on_exit(fn ->
      Sandbox.stop_owner(owner)
      Sandbox.mode(RestdisRepo, :auto)
    end)

    :ok
  end

  defp insert_config!(attrs) do
    %TenantTableConfig{}
    |> TenantTableConfig.changeset(attrs)
    |> RestdisRepo.insert!()
  end

  test "list_replicated/0 returns only tables configured in replication mode" do
    insert_config!(%{
      tenant_id: "t1",
      table_name: "orders",
      mode: "replication",
      pk_column: "order_id",
      filter: "status=eq.open"
    })

    insert_config!(%{
      tenant_id: "t1",
      table_name: "ttl_only",
      mode: "ttl"
    })

    datasets = DatasetsRepo.list_replicated()

    assert [%Dataset{} = dataset] = Enum.filter(datasets, &(&1.table == "orders"))
    assert dataset.tenant_id == "t1"
    assert dataset.schema == "public"
    assert dataset.pk_column == "order_id"
    assert dataset.filter == "status=eq.open"

    refute Enum.any?(datasets, &(&1.table == "ttl_only"))
  end

  test "list_replicated/0 returns an empty list when nothing is configured" do
    assert DatasetsRepo.list_replicated() == []
  end
end
