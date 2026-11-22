defmodule Restdis.WalTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Restdis.Cache.TestUtils
  alias Restdis.Wal.FanoutSubscriber
  alias Restdis.Wal.LsnStore
  alias Restdis.Wal.Singleton
  alias Restdis.Wal.Tailer

  defmodule NoopHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def handle_event(_event), do: :ok
  end

  defmodule ForwardingHandler do
    @behaviour Restdis.Wal.Handler

    @impl Restdis.Wal.Handler
    def handle_event(event) do
      send(:wal_temporary_test, {:event, event})
      :ok
    end
  end

  setup_all do
    TestUtils.start_syn!()
  end

  defp opts(name, extra) do
    [
      name: name,
      repo: NotARunningRepo,
      handler: NoopHandler,
      replication: [hostname: "localhost", port: 1, database: "none", sync_connect: false]
    ] ++ extra
  end

  defp children(name) do
    name
    |> Module.concat(Supervisor)
    |> Supervisor.which_children()
    |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
  end

  test "the :syn topology elects one tailer per cluster and fans events out to every node" do
    name = :"wal_syn_#{System.unique_integer([:positive])}"
    start_supervised!({Restdis.Wal, opts(name, [])})

    assert children(name) == [
             Singleton,
             FanoutSubscriber,
             Module.concat(name, TailerSupervisor),
             LsnStore
           ]
  end

  test "the :local topology runs this node's own tailer without :syn" do
    name = :"wal_local_#{System.unique_integer([:positive])}"
    start_supervised!({Restdis.Wal, opts(name, topology: :local)})

    assert children(name) == [Tailer, LsnStore]
  end

  test "a temporary instance starts without a repo" do
    name = :"wal_temporary_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Restdis.Wal, opts(name, temporary: true, topology: :local) |> Keyword.delete(:repo)}
    )

    assert children(name) == [Tailer, LsnStore]
  end

  @tag :db
  test "a temporary slot delivers changes and is dropped with its connection" do
    repo = Restdis.TestRepo
    repo.query!("CREATE TABLE wal_temporary_things (id int PRIMARY KEY)")
    repo.query!("CREATE PUBLICATION wal_temporary_pub FOR TABLE wal_temporary_things")
    Process.register(self(), :wal_temporary_test)

    start_supervised!(
      {Restdis.Wal,
       name: :wal_temporary_db,
       handler: ForwardingHandler,
       temporary: true,
       topology: :local,
       slot_name: "wal_temporary",
       publication: "wal_temporary_pub",
       replication: Keyword.take(repo.config(), [:hostname, :username, :password, :database]),
       on_takeover: {Kernel, :send, [:wal_temporary_test, :slot_created]}}
    )

    assert_receive :slot_created, 5_000

    slots = fn ->
      repo.query!(
        "SELECT temporary FROM pg_replication_slots WHERE slot_name LIKE 'wal_temporary_%'"
      ).rows
    end

    assert slots.() == [[true]]

    repo.query!("INSERT INTO wal_temporary_things VALUES (1)")
    assert_receive {:event, %{table: "wal_temporary_things", op: :insert}}, 5_000

    stop_supervised!({Restdis.Wal, :wal_temporary_db})
    assert Enum.any?(1..50, fn _ -> slots.() == [] or (Process.sleep(100) && false) end)
  end

  test "two instances run side by side" do
    a = :"wal_a_#{System.unique_integer([:positive])}"
    b = :"wal_b_#{System.unique_integer([:positive])}"

    start_supervised!({Restdis.Wal, opts(a, topology: :local)})
    start_supervised!({Restdis.Wal, opts(b, topology: :local)})

    assert children(a) == [Tailer, LsnStore]
    assert children(b) == [Tailer, LsnStore]
  end

  test "a handler is required" do
    name = :"wal_no_handler_#{System.unique_integer([:positive])}"

    assert {:error, _} =
             start_supervised({Restdis.Wal, Keyword.delete(opts(name, []), :handler)})
  end
end
