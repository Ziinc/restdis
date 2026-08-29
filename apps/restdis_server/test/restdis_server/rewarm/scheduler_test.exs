defmodule RestdisServer.Rewarm.SchedulerTest do
  use ExUnit.Case

  alias Restdis.Cache.Key
  alias RestdisServer.PolicyStore
  alias RestdisServer.QueryStore
  alias RestdisServer.Rewarm
  alias RestdisServer.Rewarm.Scheduler
  alias RestdisServer.TenantStore.InMemory

  @tenant_id "rewarm-scheduler-test-tenant"

  setup do
    Application.put_env(:restdis_server, :postgrest_fetcher, RestdisServer.StubFetcher)

    {:ok, agent} = Agent.start(fn -> 0 end)
    Application.put_env(:restdis_server, :stub_fetcher_agent, agent)
    Application.put_env(:restdis_server, :stub_fetcher_body, [%{"rewarmed" => true}])

    InMemory.seed([
      %{
        api_key: "sk_rewarm",
        tenant_id: @tenant_id,
        default_ttl_s: 60,
        persist_cap: 50_000,
        pgrst_base_url: "http://localhost:3999",
        pgrst_api_key: "svc_key",
        replica_url: nil
      }
    ])

    Restdis.Cache.flush_tenant(@tenant_id)

    on_exit(fn ->
      Application.delete_env(:restdis_server, :postgrest_fetcher)
      Application.delete_env(:restdis_server, :stub_fetcher_agent)
      Application.delete_env(:restdis_server, :stub_fetcher_body)
      Rewarm.stop_tenant(@tenant_id)
      InMemory.clear()
      Restdis.Cache.flush_tenant(@tenant_id)
      Agent.stop(agent)
    end)

    {:ok, agent: agent}
  end

  defp attach_telemetry(events) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      inspect(ref),
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    ref
  end

  test "(a) refetch fires once after rewarm_s touch", %{agent: agent} do
    attach_telemetry([:restdis_server, :rewarm, :refetch])

    key = Key.build(:table, "items", %{})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 1}], ttl_ms: 60_000)

    PolicyStore.put(@tenant_id, wire_key, %{rewarm_s: 1, persist: false})
    Rewarm.touch(@tenant_id, wire_key, key)

    assert_receive {:telemetry, [:restdis_server, :rewarm, :refetch], _, _}, 1500

    assert Agent.get(agent, & &1) == 1
    assert {:ok, [%{"rewarmed" => true}]} = Restdis.Cache.peek(@tenant_id, key)
  end

  test "(b) persist=false cold entry is evicted after one rewarm interval with no touch" do
    attach_telemetry([:restdis_server, :rewarm, :refetch])
    attach_telemetry([:restdis_server, :rewarm, :evicted])

    key = Key.build(:table, "cold_items", %{})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 2}], ttl_ms: 60_000)

    PolicyStore.put(@tenant_id, wire_key, %{rewarm_s: 1, persist: false})
    Rewarm.touch(@tenant_id, wire_key, key)

    assert_receive {:telemetry, [:restdis_server, :rewarm, :refetch], _, _}, 1500

    assert_receive {:telemetry, [:restdis_server, :rewarm, :evicted], _, meta}, 3000
    assert meta.reason == :cold

    :timer.sleep(50)
    assert :miss = Restdis.Cache.peek(@tenant_id, key)
  end

  test "(c) persist=true cold entry is NOT evicted" do
    attach_telemetry([:restdis_server, :rewarm, :refetch])
    attach_telemetry([:restdis_server, :rewarm, :evicted])

    key = Key.build(:table, "persist_items", %{})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 3}], ttl_ms: 60_000)

    pid = ensure_scheduler()
    Scheduler.upsert(pid, wire_key, key, %{rewarm_s: 1, persist: true})

    assert_receive {:telemetry, [:restdis_server, :rewarm, :refetch], _, _}, 1500

    refute_receive {:telemetry, [:restdis_server, :rewarm, :evicted], _, _}, 1500

    assert {:ok, _} = Restdis.Cache.peek(@tenant_id, key)
  end

  test "(d) policy_changed with rewarm_s nil removes row; no further refetches", %{agent: agent} do
    attach_telemetry([:restdis_server, :rewarm, :refetch])

    key = Key.build(:table, "removed_items", %{})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 4}], ttl_ms: 60_000)

    pid = ensure_scheduler()
    Scheduler.policy_changed(pid, wire_key, key, %{rewarm_s: 1, persist: false})
    Scheduler.policy_changed(pid, wire_key, key, %{rewarm_s: nil, persist: false})

    refute_receive {:telemetry, [:restdis_server, :rewarm, :refetch], _, _}, 300

    assert Agent.get(agent, & &1) == 0
  end

  test "(e) cold eviction also removes the QueryStore entry for the evicted key" do
    attach_telemetry([:restdis_server, :rewarm, :refetch])
    attach_telemetry([:restdis_server, :rewarm, :evicted])

    key = Key.build(:table, "cold_query_items", %{"id" => "eq.5"})
    wire_key = Key.encode(key)
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 5}], ttl_ms: 60_000)
    QueryStore.put(@tenant_id, wire_key, "id=eq.5")

    PolicyStore.put(@tenant_id, wire_key, %{rewarm_s: 1, persist: false})
    Rewarm.touch(@tenant_id, wire_key, key)

    assert_receive {:telemetry, [:restdis_server, :rewarm, :refetch], _, _}, 1500
    assert_receive {:telemetry, [:restdis_server, :rewarm, :evicted], _, meta}, 3000
    assert meta.reason == :cold

    :timer.sleep(50)
    assert QueryStore.get(@tenant_id, wire_key) == ""
  end

  test "(f) stop_tenant clears the tenant's QueryStore entries" do
    key = Key.build(:table, "teardown_items", %{"id" => "eq.9"})
    wire_key = Key.encode(key)
    QueryStore.put(@tenant_id, wire_key, "id=eq.9")

    pid = ensure_scheduler()
    assert Process.alive?(pid)

    Rewarm.stop_tenant(@tenant_id)

    assert QueryStore.get(@tenant_id, wire_key) == ""
  end

  test "(g) rewarm refetch reuses the original query string, not the bare path" do
    Application.delete_env(:restdis_server, :postgrest_fetcher)

    key = Key.build(:table, "filtered_items", %{"id" => "eq.1"})
    wire_key = Key.encode(key)
    QueryStore.put(@tenant_id, wire_key, "id=eq.1")
    Restdis.Cache.put(@tenant_id, key, [%{"id" => 1}], ttl_ms: 60_000)

    test_pid = self()

    Req.Test.stub(RestdisServer.Finch, fn conn ->
      send(test_pid, {:outbound_query, conn.query_string})
      Req.Test.json(conn, [%{"id" => 1}])
    end)

    PolicyStore.put(@tenant_id, wire_key, %{rewarm_s: 1, persist: false})
    Rewarm.touch(@tenant_id, wire_key, key)

    scheduler_pid = ensure_scheduler()
    Req.Test.allow(RestdisServer.Finch, test_pid, scheduler_pid)

    assert_receive {:outbound_query, query_string}, 1500
    assert query_string == "id=eq.1"
  end

  defp ensure_scheduler do
    case Registry.lookup(RestdisServer.Rewarm.Registry, @tenant_id) do
      [{pid, _}] ->
        pid

      [] ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            RestdisServer.Rewarm.DynamicSupervisor,
            {Scheduler, tenant_id: @tenant_id}
          )

        pid
    end
  end
end
