defmodule RestdisServer.Commands.SetArgumentErrorsTest do
  use ExUnit.Case, async: false

  import RestdisServer.TestUtils

  alias Restdis.Cache.Key
  alias RestdisServer.Commands.Set

  setup do
    tenant_id = "tenant_set_errors_#{System.unique_integer([:positive])}"
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "SET with the wrong number of arguments replies with an error", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), [])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"

    {reply, _state} = Set.run(state(tenant_id), ["onlykey"])
    assert IO.iodata_to_binary(reply) =~ "wrong number of arguments"
  end

  test "SET rejects pgrst:* wire keys", %{tenant_id: tenant_id} do
    wire_key = Key.encode(Key.build(:table, "products", %{}))
    {reply, _state} = Set.run(state(tenant_id), [wire_key, "value"])
    assert IO.iodata_to_binary(reply) =~ "managed by PGRST.QUERY"
  end

  test "SET rejects <table>:<primary_key>-shaped keys", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["products:42", "value"])
    assert IO.iodata_to_binary(reply) =~ "reserved"
  end

  test "SET with a malformed EX option replies with a syntax error", %{tenant_id: tenant_id} do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "value", "EX", "notanumber"])
    assert IO.iodata_to_binary(reply) == "-ERR syntax error\r\n"
  end

  test "SET with an unrecognized trailing option replies with a syntax error", %{
    tenant_id: tenant_id
  } do
    {reply, _state} = Set.run(state(tenant_id), ["mykey", "value", "BADOPT"])
    assert IO.iodata_to_binary(reply) == "-ERR syntax error\r\n"
  end
end
