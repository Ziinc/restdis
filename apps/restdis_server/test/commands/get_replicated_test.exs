defmodule RestdisServer.Commands.GetReplicatedTest do
  use ExUnit.Case, async: false

  alias RestdisReplicator.Dataset
  alias RestdisServer.Commands.Get

  setup do
    tenant_id = "tenant_get_replicated_#{System.unique_integer([:positive])}"
    dataset = Dataset.new(%{tenant_id: tenant_id, table_name: "products", pk_column: "id"})

    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)

    {:ok, tenant_id: tenant_id, dataset: dataset}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "GET <table>:<pk> serves a replicated row", %{tenant_id: tenant_id, dataset: dataset} do
    row = %{"id" => 42, "name" => "widget"}
    Restdis.Cache.put(tenant_id, Dataset.cache_key(dataset, 42), row, primary_keys: ["42"])

    {reply, _state} = Get.run(state(tenant_id), ["products:42"])

    assert IO.iodata_to_binary(reply) ==
             "$#{byte_size(Jason.encode!(row))}\r\n#{Jason.encode!(row)}\r\n"
  end

  test "GET <table>:<pk> replies null when the row is not replicated", %{tenant_id: tenant_id} do
    {reply, _state} = Get.run(state(tenant_id), ["products:999"])

    assert IO.iodata_to_binary(reply) == "$-1\r\n"
  end

  test "GET of a key that is neither a PGRST nor a KV key errors", %{tenant_id: tenant_id} do
    {reply, _state} = Get.run(state(tenant_id), ["products"])

    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
