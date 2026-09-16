defmodule RestdisReplicator.ReconcilerTest do
  use ExUnit.Case, async: false

  alias RestdisReplicator.Reconciler
  alias RestdisReplicator.TestUtils

  defmodule StubSource do
    def list_replicated do
      :persistent_term.get({__MODULE__, :datasets}, [])
    end

    def put(datasets) do
      :persistent_term.put({__MODULE__, :datasets}, datasets)
    end
  end

  setup do
    first = TestUtils.dataset()
    second = TestUtils.dataset()
    StubSource.put([first, second])

    Application.put_env(
      :restdis_replicator,
      :dataset_source,
      {StubSource, :list_replicated, []}
    )

    on_exit(fn ->
      Application.put_env(:restdis_replicator, :dataset_source, nil)
      :persistent_term.erase({StubSource, :datasets})
      TestUtils.cleanup(first)
      TestUtils.cleanup(second)
    end)

    {:ok, first: first, second: second}
  end

  test "reconciliation leaves zero stale entries across datasets", %{
    first: first,
    second: second
  } do
    TestUtils.seed(first, TestUtils.rows(first, 3))
    TestUtils.seed(second, TestUtils.rows(second, 2))
    {:ok, _} = RestdisReplicator.subscribe(first)
    {:ok, _} = RestdisReplicator.subscribe(second)

    # Rows change while the WAL tailer is down.
    TestUtils.seed(first, [%{"id" => 1, "name" => "row-1"}])
    TestUtils.seed(second, [%{"id" => 2, "name" => "changed"}])

    assert [_, _] = Reconciler.reconcile_all_sync()

    assert :miss = RestdisReplicator.get(first.tenant_id, first.table, 2)
    assert :miss = RestdisReplicator.get(first.tenant_id, first.table, 3)
    assert {:ok, %{"name" => "row-1"}} = RestdisReplicator.get(first.tenant_id, first.table, 1)
    assert :miss = RestdisReplicator.get(second.tenant_id, second.table, 1)

    assert {:ok, %{"name" => "changed"}} =
             RestdisReplicator.get(second.tenant_id, second.table, 2)
  end

  test "reconcile_all/0 staggers reconciliation of every dataset", %{first: first, second: second} do
    TestUtils.seed(first, TestUtils.rows(first, 1))
    TestUtils.seed(second, TestUtils.rows(second, 1))

    :ok = RestdisReplicator.reconcile_all()

    assert eventually(fn ->
             match?({:ok, _}, RestdisReplicator.get(first.tenant_id, first.table, 1)) and
               match?({:ok, _}, RestdisReplicator.get(second.tenant_id, second.table, 1))
           end)
  end

  test "reconcile_all/0 without a dataset source is a no-op" do
    Application.put_env(:restdis_replicator, :dataset_source, nil)

    assert :ok = RestdisReplicator.reconcile_all()
    assert Reconciler.reconcile_all_sync() == []
  end

  test "handle_info/2 ignores unrelated messages" do
    send(Process.whereis(Reconciler), :some_unrelated_message)

    assert Process.alive?(Process.whereis(Reconciler))
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
