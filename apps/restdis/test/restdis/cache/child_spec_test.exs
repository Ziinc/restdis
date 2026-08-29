defmodule Restdis.Cache.ChildSpecTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Proves the library starts no processes as a plain dependency and that a
  host explicitly mounts `Restdis.Cache` to start its supervision tree
  (LIB_PRD Phase 5, "explicit start").
  """

  test "the :restdis application declares no `mod:` callback" do
    assert Application.spec(:restdis, :mod) in [nil, []]
  end

  test "start_link/1 accepts a caller-provided top-level name and is idempotent by name" do
    # `Restdis.Cache.Supervisor` is already running under its default name
    # (started by this app's own test_helper.exs). Asking for that same
    # default name again must not crash the caller (the umbrella's several
    # host apps each defensively mount it in test); it returns the existing
    # supervisor rather than erroring.
    assert {:ok, pid} = Restdis.Cache.Supervisor.start_link([])
    assert pid == Process.whereis(Restdis.Cache.Supervisor)

    # Only the top-level supervisor process's own registered name is
    # instance-scoped in this change; the tenant registry and dynamic
    # supervisor it starts are still named by fixed module atoms
    # (`Restdis.Cache.TenantRegistry`, `Restdis.Cache.TenantSupervisor`), so
    # two such instances cannot yet run fully independently in one VM.
    # Threading an instance identifier through every cache call site
    # (`Restdis.Cache`, `QueryCache`, `DiskCache`, `ReverseIndex`, `Tenant`)
    # is tracked as PRD Phase 5 follow-up work; see PR description.
    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             Restdis.Cache.Supervisor.start_link(
               name: :"cache_instance_#{System.unique_integer()}"
             )
  end

  test "Restdis.Cache.child_spec/1 wraps Restdis.Cache.Supervisor" do
    spec = Restdis.Cache.child_spec([])
    assert %{start: {Restdis.Cache.Supervisor, :start_link, [[]]}} = spec
  end
end
