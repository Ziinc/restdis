defmodule Restdis.Cache.ChildSpecTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Proves the library starts no processes as a plain dependency and that a
  host explicitly mounts `Restdis.Cache` to start its supervision tree
  (LIB_PRD Phase 5, "explicit start").
  """

  alias Restdis.Cache.Key

  test "the :restdis application declares no `mod:` callback" do
    assert Application.spec(:restdis, :mod) in [nil, []]
  end

  test "start_link/1 accepts a caller-provided top-level name and is idempotent by name" do
    # Already running under its default name; asking again must return the existing supervisor, not error.
    assert {:ok, pid} = Restdis.Cache.Supervisor.start_link([])
    assert pid == Process.whereis(Restdis.Cache)
  end

  test "a second instance with a different :name runs alongside the default one" do
    name = :"cache_instance_#{System.unique_integer([:positive])}"
    data_dir = Path.join(System.tmp_dir!(), "restdis_second_instance_#{System.unique_integer()}")

    assert {:ok, pid} =
             Restdis.Cache.Supervisor.start_link(
               name: name,
               data_dir: data_dir,
               origin: Restdis.Cache.Origin.Stub
             )

    # Unlinked so this test process's own exit can't race the on_exit stop below.
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
      File.rm_rf!(data_dir)
    end)

    assert pid == Process.whereis(name)
    refute pid == Process.whereis(Restdis.Cache)

    tenant_id = "second_instance_#{System.unique_integer([:positive])}"
    key = Key.build(:table, "widgets", %{})

    assert :ok = Restdis.Cache.put(tenant_id, key, "v", name: name)
    assert {:ok, "v"} = Restdis.Cache.peek(tenant_id, key, name)
    assert :miss = Restdis.Cache.peek(tenant_id, key)
  end

  test "Restdis.Cache.child_spec/1 wraps Restdis.Cache.Supervisor" do
    spec = Restdis.Cache.child_spec([])
    assert %{start: {Restdis.Cache.Supervisor, :start_link, [[]]}} = spec
  end
end
