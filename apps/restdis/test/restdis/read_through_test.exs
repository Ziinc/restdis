defmodule Restdis.Cache.ReadThroughTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.QueryCache
  alias Restdis.Cache.ReadThrough

  setup context do
    name = :"rt_#{System.unique_integer([:positive])}"
    data_dir = Path.join(System.tmp_dir!(), "restdis_rt_#{System.unique_integer([:positive])}")
    ttl_ms = Map.get(context, :ttl_ms, 60_000)

    start_supervised!({ReadThrough, name: name, data_dir: data_dir, ttl_ms: ttl_ms})
    on_exit(fn -> File.rm_rf!(data_dir) end)

    %{name: name, data_dir: data_dir}
  end

  test "fetch/3 loads on a miss and serves later reads from the cache", %{name: name} do
    test_pid = self()

    loader = fn ->
      send(test_pid, :loaded)
      {:ok, %{tenant_id: "acme"}}
    end

    assert {:ok, %{tenant_id: "acme"}} = ReadThrough.fetch(name, "tenants/acme", loader)
    assert_received :loaded

    assert {:ok, %{tenant_id: "acme"}} = ReadThrough.fetch(name, "tenants/acme", loader)
    refute_received :loaded
  end

  test "fetch/3 falls back to the disk layer when the query cache is empty", %{name: name} do
    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)

    QueryCache.flush(ReadThrough.namespace(name))

    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> flunk("loader ran") end)
  end

  @tag ttl_ms: 1
  test "fetch/3 reloads once every layer has expired", %{name: name} do
    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)
    Process.sleep(5)
    QueryCache.flush(ReadThrough.namespace(name))

    assert {:ok, 2} = ReadThrough.fetch(name, "k", fn -> {:ok, 2} end)
  end

  test "fetch/3 does not cache a loader miss", %{name: name} do
    assert {:error, :not_found} = ReadThrough.fetch(name, "k", fn -> {:error, :not_found} end)
    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)
  end

  test "delete/2 removes the entry from every layer", %{name: name} do
    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)
    assert :ok = ReadThrough.delete(name, "k")

    assert {:ok, 2} = ReadThrough.fetch(name, "k", fn -> {:ok, 2} end)
  end

  test "flush/1 removes every entry from every layer", %{name: name} do
    assert {:ok, 1} = ReadThrough.fetch(name, "a", fn -> {:ok, 1} end)
    assert {:ok, 1} = ReadThrough.fetch(name, "b", fn -> {:ok, 1} end)
    assert :ok = ReadThrough.flush(name)

    assert {:ok, 2} = ReadThrough.fetch(name, "a", fn -> {:ok, 2} end)
    assert {:ok, 2} = ReadThrough.fetch(name, "b", fn -> {:ok, 2} end)
  end

  test "put/3 writes a value readable without a loader", %{name: name} do
    assert :ok = ReadThrough.put(name, "k", :v)
    assert {:ok, :v} = ReadThrough.fetch(name, "k", fn -> flunk("loader ran") end)
  end

  test "two caches started under different names hold separate entries", %{
    name: name,
    data_dir: data_dir
  } do
    other = :"rt_other_#{System.unique_integer([:positive])}"
    start_supervised!({ReadThrough, name: other, data_dir: data_dir, ttl_ms: 60_000})

    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> {:ok, 1} end)
    assert {:ok, 2} = ReadThrough.fetch(other, "k", fn -> {:ok, 2} end)
    assert {:ok, 1} = ReadThrough.fetch(name, "k", fn -> flunk("loader ran") end)
  end
end
