defmodule RestdisElectric.LogTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias RestdisElectric.Log
  alias RestdisElectric.Message
  alias RestdisElectric.Offset
  alias RestdisElectric.ShapeRegistry
  alias RestdisElectric.TestUtils

  import RestdisElectric.TestUtils, only: [eventually: 1]

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

    result =
      eventually do
        Log.read(tenant_id, handle, Offset.beginning())
      end

    assert {:ok, [^message], {0, 0}} = result
  end

  test "waiting?/2 is false for a handle with no log process and no waiters" do
    tenant_id = TestUtils.tenant_id()
    assert Log.waiting?(tenant_id, "unknown-handle") == false
  end

  test "waiting?/2 is true while a client is blocked in await/4 and false again once it wakes" do
    tenant_id = TestUtils.tenant_id()
    handle = "h-waiting"
    :ok = Log.append(tenant_id, handle, [Message.change({0, 0}, :insert, "1", %{"id" => 1})])

    parent = self()

    spawn(fn ->
      result = Log.await(tenant_id, handle, {0, 0}, 5_000)
      send(parent, {:awaited, result})
    end)

    Process.sleep(50)
    assert Log.waiting?(tenant_id, handle) == true

    new_message = Message.change({0, 1}, :insert, "2", %{"id" => 2})
    :ok = Log.append(tenant_id, handle, [new_message])

    assert_receive {:awaited, {:ok, [^new_message], {0, 1}}}, 1_000
    assert Log.waiting?(tenant_id, handle) == false
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

  test "truncated_before/2 is nil for a shape with no retention limit configured" do
    tenant_id = TestUtils.tenant_id()
    handle = "h-no-retention"
    :ok = ShapeRegistry.register(tenant_id, "public", "widgets", handle)
    :ok = Log.append(tenant_id, handle, [Message.change({0, 0}, :insert, "1", %{"id" => 1})])

    assert Log.truncated_before(tenant_id, handle) == nil
  end

  test "append/3 truncates the front of the log once it exceeds the shape's effective retention" do
    tenant_id = TestUtils.tenant_id()
    handle = "h-retention"

    definition = %RestdisElectric.Definition{
      tenant_id: tenant_id,
      schema: "public",
      table: "widgets",
      retention: 3
    }

    :ok = ShapeRegistry.register(tenant_id, definition, handle)

    messages =
      for n <- 0..9, do: Message.change({0, n}, :insert, Integer.to_string(n), %{"id" => n})

    :ok = Log.append(tenant_id, handle, messages)

    assert {:ok, kept, {0, 9}} = Log.read(tenant_id, handle, Offset.beginning())
    assert Enum.map(kept, & &1.offset) == [{0, 7}, {0, 8}, {0, 9}]
    assert Log.truncated_before(tenant_id, handle) == {0, 6}
  end

  test "resuming from an offset inside the retained window still succeeds" do
    tenant_id = TestUtils.tenant_id()
    handle = "h-retention-ok"

    definition = %RestdisElectric.Definition{
      tenant_id: tenant_id,
      schema: "public",
      table: "widgets",
      retention: 3
    }

    :ok = ShapeRegistry.register(tenant_id, definition, handle)

    messages =
      for n <- 0..9, do: Message.change({0, n}, :insert, Integer.to_string(n), %{"id" => n})

    :ok = Log.append(tenant_id, handle, messages)

    # {0, 6} is exactly the truncation boundary; resuming from it should still work.
    assert {:ok, tail, {0, 9}} = Log.read(tenant_id, handle, {0, 6})
    assert Enum.map(tail, & &1.offset) == [{0, 7}, {0, 8}, {0, 9}]
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
