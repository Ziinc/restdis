defmodule RestdisElectric.LogTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.Offset
  alias RestdisElectric.TestUtils

  test "read/3 returns nothing for a handle that was never written" do
    tenant_id = TestUtils.tenant_id()
    assert :error = Log.read(tenant_id, "unknown-handle", Offset.beginning())
  end

  test "append/3 then read/3 from beginning returns every message in order" do
    tenant_id = TestUtils.tenant_id()
    handle = "h1"

    messages = [
      Message.change({0, 0}, :insert, "1", %{"id" => 1}),
      Message.change({0, 1}, :insert, "2", %{"id" => 2})
    ]

    :ok = Log.append(tenant_id, handle, messages)

    assert {:ok, ^messages, {0, 1}} = Log.read(tenant_id, handle, Offset.beginning())
  end

  test "append/3 rejects a write that would push the log past the tenant's max_log_bytes" do
    tenant_id = TestUtils.tenant_id()
    handle = "h-limit"
    RestdisElectric.Limits.put_config(tenant_id, %{max_log_bytes: 10})

    message =
      Message.change({0, 0}, :insert, "1", %{"id" => 1, "name" => String.duplicate("a", 50)})

    assert {:error, {:limit_exceeded, :log_bytes, 10}} = Log.append(tenant_id, handle, [message])
    assert {:ok, [], :beginning} = Log.read(tenant_id, handle, Offset.beginning())
  end

  test "read/3 resumes strictly after the given offset, dropping none and reordering none" do
    tenant_id = TestUtils.tenant_id()
    handle = "h2"

    messages =
      for n <- 0..9, do: Message.change({0, n}, :insert, Integer.to_string(n), %{"id" => n})

    :ok = Log.append(tenant_id, handle, messages)

    assert {:ok, tail, {0, 9}} = Log.read(tenant_id, handle, {0, 4})
    assert Enum.map(tail, & &1.offset) == for(n <- 5..9, do: {0, n})
  end

  test "the log survives a process restart" do
    tenant_id = TestUtils.tenant_id()
    handle = "h3"
    message = Message.change({0, 0}, :insert, "1", %{"id" => 1})

    :ok = Log.append(tenant_id, handle, [message])

    {:ok, pid} = Log.ensure_started(tenant_id, handle)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert {:ok, [^message], {0, 0}} = Log.read(tenant_id, handle, Offset.beginning())
  end

  test "delete/2 removes the log" do
    tenant_id = TestUtils.tenant_id()
    handle = "h4"
    :ok = Log.append(tenant_id, handle, [Message.change({0, 0}, :insert, "1", %{"id" => 1})])

    :ok = Log.delete(tenant_id, handle)

    assert :error = Log.read(tenant_id, handle, Offset.beginning())
  end

  test "await/4 wakes immediately when the log already has newer data" do
    tenant_id = TestUtils.tenant_id()
    handle = "h5"
    message = Message.change({0, 0}, :insert, "1", %{"id" => 1})
    :ok = Log.append(tenant_id, handle, [message])

    assert {:ok, [^message], {0, 0}} = Log.await(tenant_id, handle, Offset.beginning(), 100)
  end

  test "await/4 wakes once a later append arrives" do
    tenant_id = TestUtils.tenant_id()
    handle = "h6"
    :ok = Log.append(tenant_id, handle, [Message.change({0, 0}, :insert, "1", %{"id" => 1})])

    parent = self()

    spawn(fn ->
      result = Log.await(tenant_id, handle, {0, 0}, 5_000)
      send(parent, {:awaited, result})
    end)

    Process.sleep(50)
    new_message = Message.change({0, 1}, :insert, "2", %{"id" => 2})
    :ok = Log.append(tenant_id, handle, [new_message])

    assert_receive {:awaited, {:ok, [^new_message], {0, 1}}}, 1_000
  end

  test "await/4 times out when nothing new arrives" do
    tenant_id = TestUtils.tenant_id()
    handle = "h7"
    :ok = Log.append(tenant_id, handle, [Message.change({0, 0}, :insert, "1", %{"id" => 1})])

    assert :timeout = Log.await(tenant_id, handle, {0, 0}, 100)
  end

  property "replaying from any offset produces the same tail as replaying from beginning" do
    check all(
            count <- StreamData.integer(1..20),
            resume_at <- StreamData.integer(0..19)
          ) do
      tenant_id = TestUtils.tenant_id()
      handle = "prop-#{System.unique_integer([:positive])}"

      messages =
        for n <- 0..(count - 1), do: Message.change({0, n}, :insert, Integer.to_string(n), %{})

      :ok = Log.append(tenant_id, handle, messages)

      {:ok, all_messages, _} = Log.read(tenant_id, handle, Offset.beginning())
      {:ok, tail, _} = Log.read(tenant_id, handle, {0, resume_at})

      expected = Enum.filter(all_messages, fn m -> Offset.before?({0, resume_at}, m.offset) end)
      assert tail == expected
    end
  end
end
