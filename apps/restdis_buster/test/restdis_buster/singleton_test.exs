defmodule RestdisBuster.SingletonTest do
  use ExUnit.Case, async: false

  alias RestdisBuster.Singleton

  test ":syn :wal scope allows only one registration per name" do
    parent = self()

    p1 =
      spawn(fn ->
        result = :syn.register(:wal, :test_tailer, self())
        send(parent, {:p1_register, result})

        receive do
          :stop -> :ok
        after
          2_000 -> :ok
        end
      end)

    # Wait for p1 to register
    assert_receive {:p1_register, :ok}, 500

    p2 =
      spawn(fn ->
        result = :syn.register(:wal, :test_tailer, self())
        send(parent, {:p2_register, result})
      end)

    assert_receive {:p2_register, {:error, :taken}}, 500

    # After p1 dies, p2 would be able to register
    send(p1, :stop)
    Process.sleep(100)

    p3 =
      spawn(fn ->
        result = :syn.register(:wal, :test_tailer, self())
        send(parent, {:p3_register, result})

        receive do
          :stop -> :ok
        after
          500 -> :ok
        end
      end)

    assert_receive {:p3_register, :ok}, 500
    send(p3, :stop)

    Process.exit(p1, :kill)
    Process.exit(p2, :kill)
  end

  test ":syn :wal_fanout group receives published messages" do
    az = "singleton_test_az"
    parent = self()

    sub1 =
      spawn(fn ->
        :syn.join(:wal_fanout, {:az, az}, self())

        receive do
          msg -> send(parent, {:sub1, msg})
        after
          500 -> send(parent, :sub1_timeout)
        end
      end)

    sub2 =
      spawn(fn ->
        :syn.join(:wal_fanout, {:az, az}, self())

        receive do
          msg -> send(parent, {:sub2, msg})
        after
          500 -> send(parent, :sub2_timeout)
        end
      end)

    Process.sleep(50)

    :syn.publish(:wal_fanout, {:az, az}, :hello)

    assert_receive {:sub1, :hello}, 300
    assert_receive {:sub2, :hello}, 300

    Process.exit(sub1, :kill)
    Process.exit(sub2, :kill)
  end

  describe "handle_info/2 (direct callback invocation)" do
    # The application's own `RestdisBuster.Singleton` already owns
    # `{:wal, :wal_tailer}` for the real `RestdisBuster.Tailer`. Calling the
    # (public, `@impl`) `handle_info/2` callback directly - rather than via
    # message-passing to the running GenServer - lets us exercise its
    # branches deterministically without disturbing that real singleton's
    # own state.

    test ":try_register loses the election to the already-registered winner and monitors it" do
      assert {pid, _meta} = :syn.lookup(:wal, :wal_tailer)

      assert {:noreply, %{tailer: nil}} =
               Singleton.handle_info(:try_register, %{tailer: nil})

      assert Process.alive?(pid)
    end

    test "an unrelated :DOWN (not the owned tailer) triggers a takeover attempt" do
      fake_pid = spawn(fn -> :ok end)

      assert {:noreply, %{tailer: nil}} =
               Singleton.handle_info({:DOWN, make_ref(), :process, fake_pid, :normal}, %{
                 tailer: nil
               })

      assert_received :try_register
    end

    test "the owned tailer crashing unregisters it and retries" do
      {real_tailer_pid, _meta} = :syn.lookup(:wal, :wal_tailer)
      on_exit(fn -> :syn.register(:wal, :wal_tailer, real_tailer_pid) end)

      assert {:noreply, %{tailer: nil}} =
               Singleton.handle_info(
                 {:DOWN, make_ref(), :process, real_tailer_pid, :boom},
                 %{tailer: real_tailer_pid}
               )

      assert_received :try_register
      assert :syn.lookup(:wal, :wal_tailer) == :undefined
    end

    test "unrecognized messages are ignored" do
      assert {:noreply, %{some: :state}} = Singleton.handle_info(:whatever, %{some: :state})
    end
  end
end
