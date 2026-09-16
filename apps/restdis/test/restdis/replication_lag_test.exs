defmodule Restdis.Cache.ReplicationLagTest do
  use ExUnit.Case, async: false

  alias Restdis.Cache.Key
  alias Restdis.Cache.Replication.Receiver
  alias Restdis.Cache.TestUtils

  setup do
    tenant_id = TestUtils.start_tenant("lag")
    on_exit(fn -> Restdis.Cache.flush_tenant(tenant_id) end)
    {:ok, tenant_id: tenant_id}
  end

  test "a stamped peer message reports its replication lag and is applied", %{
    tenant_id: tenant_id
  } do
    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:restdis, :replication, :lag],
      fn _event, measurements, metadata, pid -> send(pid, {:lag, measurements, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    key = Key.build(:table, "widgets", %{})
    sent_at_us = System.system_time(:microsecond) - 5_000
    event = {:put, key, "v", [persist: true]}

    GenServer.cast(
      Receiver.process_name(Restdis.Cache),
      {:sc_replication_stamped, {:sc_replication, Restdis.Cache, tenant_id, event}, sent_at_us}
    )

    assert_receive {:lag, %{lag_us: lag_us}, %{tenant_id: ^tenant_id}}
    assert lag_us >= 5_000

    assert :ok = GenServer.call(Receiver.process_name(Restdis.Cache), :sync)
    assert {:ok, "v"} = Restdis.Cache.peek(tenant_id, key)
  end
end
