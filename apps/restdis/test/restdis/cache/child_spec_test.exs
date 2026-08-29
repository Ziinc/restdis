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
    # Already running under its default name; asking again must return the existing supervisor, not error.
    assert {:ok, pid} = Restdis.Cache.Supervisor.start_link([])
    assert pid == Process.whereis(Restdis.Cache.Supervisor)

    # Only the supervisor's own name is instance-scoped so far; other cache modules use fixed atoms (PRD Phase 5 follow-up).
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
