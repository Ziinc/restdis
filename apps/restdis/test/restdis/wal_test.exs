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
