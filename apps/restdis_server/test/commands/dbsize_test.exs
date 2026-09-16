defmodule RestdisServer.Commands.DbsizeTest do
  use ExUnit.Case, async: false

  alias RestdisServer.Commands.Dbsize
  alias RestdisServer.Commands.Del
  alias RestdisServer.Commands.Set

  setup do
    tenant_id = "tenant_dbsize_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  defp state(tenant_id), do: %{authenticated?: true, tenant_id: tenant_id, buffer: <<>>}

  test "DBSIZE reflects the number of keys stored for the tenant", %{tenant_id: tenant_id} do
    {reply, _state} = Dbsize.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) == ":0\r\n"

    Set.run(state(tenant_id), ["key1", "one"])
    Set.run(state(tenant_id), ["key2", "two"])

    {reply2, _state} = Dbsize.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply2) == ":2\r\n"

    Del.run(state(tenant_id), ["key1"])

    {reply3, _state} = Dbsize.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply3) == ":1\r\n"
  end

  test "DBSIZE with arguments errors", %{tenant_id: tenant_id} do
    {reply, _state} = Dbsize.run(state(tenant_id), ["extra"])
    assert IO.iodata_to_binary(reply) =~ "ERR"
  end
end
