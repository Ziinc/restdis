defmodule Restdis.Cache.RouterTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.Router
  alias Restdis.Cache.TestUtils

  @ghost :"ghost@127.0.0.1"

  setup do
    on_exit(fn -> TestUtils.remove_cluster_node(@ghost) end)
    :ok
  end

  describe "locally owned tenants" do
    setup do
      tenant_id = TestUtils.start_tenant("router")
      on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
      {:ok, tenant_id: tenant_id}
    end

    test "put and peek are served locally", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert Router.owner(tenant_id) == Node.self()
      assert :ok = Router.put(tenant_id, key, [%{"id" => 1}])
      assert {:ok, [%{"id" => 1}]} = Router.peek(tenant_id, key)
      assert {:ok, [%{"id" => 1}]} = Router.get(tenant_id, key)
    end

    test "delete is served locally", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{"a" => "1"})
      assert :ok = Router.put(tenant_id, key, "v")

      assert :ok = Router.delete(tenant_id, key)
      assert :miss = Router.peek(tenant_id, key)
    end
  end

  describe "remotely owned tenants" do
    setup do
      TestUtils.add_cluster_node(@ghost)
      {:ok, tenant_id: TestUtils.tenant_owned_by(@ghost)}
    end

    test "an unreachable owner answers {:error, :unreachable}", %{tenant_id: tenant_id} do
      key = Key.build(:table, "widgets", %{})

      assert Router.owner(tenant_id) == @ghost
      assert {:error, :unreachable} = Router.peek(tenant_id, key)
      assert {:error, :unreachable} = Router.get(tenant_id, key)
      assert {:error, :unreachable} = Router.put(tenant_id, key, "v")
      assert {:error, :unreachable} = Router.delete(tenant_id, key)
    end

    test "forwarding a request to a remote owner is counted", %{tenant_id: tenant_id} do
      handler = {__MODULE__, self()}

      :telemetry.attach_many(
        handler,
        [
          [:restdis, :cluster, :forward],
          [:restdis, :cluster, :unreachable]
        ],
        fn event, _measurements, metadata, pid -> send(pid, {:event, event, metadata}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Router.peek(tenant_id, Key.build(:table, "widgets", %{}))

      assert_receive {:event, [:restdis, :cluster, :forward],
                      %{owner: @ghost, op: :peek}}

      assert_receive {:event, [:restdis, :cluster, :unreachable],
                      %{owner: @ghost, op: :peek}}
    end

    test "the unreachable owner is given up on within one second", %{tenant_id: tenant_id} do
      {elapsed_us, {:error, :unreachable}} =
        :timer.tc(fn -> Router.peek(tenant_id, Key.build(:table, "widgets", %{})) end)

      assert elapsed_us <= 1_100_000
    end
  end
end
