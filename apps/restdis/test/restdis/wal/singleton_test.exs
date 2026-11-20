defmodule Restdis.Wal.SingletonTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Restdis.Cache.TestUtils
  alias Restdis.Wal.InstanceConfig
  alias Restdis.Wal.Singleton

  @name :wal_singleton_test

  setup_all do
    TestUtils.start_syn!()

    InstanceConfig.put(@name,
      repo: NotARunningRepo,
      replication: [hostname: "localhost", port: 1, database: "none", sync_connect: false],
      on_takeover: {Kernel, :send, [:wal_singleton_test, :took_over]}
    )

    InstanceConfig.put(:wal_lost_election, repo: NotARunningRepo)
    InstanceConfig.put(:wal_crashed_tailer, repo: NotARunningRepo)
  end

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

  test "the elected owner starts the instance's tailer and runs its on_takeover callback" do
    Process.register(self(), :wal_singleton_test)
    start_supervised!({DynamicSupervisor, name: Module.concat(@name, TailerSupervisor)})
    start_supervised!({Singleton, name: @name})

    assert_receive :took_over, 1_000

    assert [{_, tailer, _, _}] =
             DynamicSupervisor.which_children(Module.concat(@name, TailerSupervisor))

    assert Process.alive?(tailer)
  end

  describe "handle_info/2 (direct callback invocation)" do
    # Calls `handle_info/2` directly to exercise branches without a running singleton.

    test ":try_register loses the election to the already-registered winner and monitors it" do
      winner = spawn(fn -> Process.sleep(:infinity) end)
      :ok = :syn.register(:wal, {:wal_lost_election, :wal_tailer}, winner)
      on_exit(fn -> Process.exit(winner, :kill) end)

      assert {:noreply, %{tailer: nil}} =
               Singleton.handle_info(:try_register, %{name: :wal_lost_election, tailer: nil})

      assert Process.alive?(winner)
    end

    test "an unrelated :DOWN (not the owned tailer) triggers a takeover attempt" do
      fake_pid = spawn(fn -> :ok end)

      assert {:noreply, %{tailer: nil}} =
               Singleton.handle_info({:DOWN, make_ref(), :process, fake_pid, :normal}, %{
                 name: @name,
                 tailer: nil
               })

      assert_received :try_register
    end

    test "the owned tailer crashing unregisters it and retries" do
      tailer = spawn(fn -> :ok end)
      :ok = :syn.register(:wal, {:wal_crashed_tailer, :wal_tailer}, self())

      assert {:noreply, %{tailer: nil}} =
               Singleton.handle_info(
                 {:DOWN, make_ref(), :process, tailer, :boom},
                 %{name: :wal_crashed_tailer, tailer: tailer}
               )

      assert_received :try_register
      assert :syn.lookup(:wal, {:wal_crashed_tailer, :wal_tailer}) == :undefined
    end

    test "unrecognized messages are ignored" do
      assert {:noreply, %{some: :state}} = Singleton.handle_info(:whatever, %{some: :state})
    end
  end
end
