defmodule RestdisBuster.CompositeInvalidatorTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.CompositeInvalidator

  defmodule OkA do
    def invalidate(tenant_id) do
      send(:composite_test, {:a, tenant_id})
      :ok
    end
  end

  defmodule Raising do
    def invalidate(_tenant_id), do: raise("boom")
  end

  defmodule OkB do
    def invalidate(tenant_id) do
      send(:composite_test, {:b, tenant_id})
      :ok
    end
  end

  setup do
    Process.register(self(), :composite_test)
    prev = Application.get_env(:restdis_buster, :tenant_config_invalidator_chain)

    on_exit(fn ->
      Application.put_env(:restdis_buster, :tenant_config_invalidator_chain, prev || [])

      try do
        Process.unregister(:composite_test)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "calls each impl in the chain in order" do
    Application.put_env(:restdis_buster, :tenant_config_invalidator_chain, [OkA, OkB])

    assert :ok = CompositeInvalidator.invalidate("t1")

    assert_receive {:a, "t1"}
    assert_receive {:b, "t1"}
  end

  test "an impl that raises does not block subsequent impls" do
    Application.put_env(:restdis_buster, :tenant_config_invalidator_chain, [OkA, Raising, OkB])

    assert :ok = CompositeInvalidator.invalidate("t2")

    assert_receive {:a, "t2"}
    assert_receive {:b, "t2"}
  end

  test "empty chain is a no-op" do
    Application.put_env(:restdis_buster, :tenant_config_invalidator_chain, [])
    assert :ok = CompositeInvalidator.invalidate("t3")
  end
end
