defmodule RestdisBuster.Integration.WalInvalidationTest do
  @moduledoc """
  End-to-end WAL invalidation test against a real Postgres with
  `wal_level = logical`.

  Excluded by default via `ExUnit.start(exclude: [:integration])`. Run with:

      mix test --only integration

  These tests bypass the Ecto sandbox because logical replication needs
  committed WAL records. A dedicated Postgrex connection (`:fixture_conn`)
  is opened in `setup_all` for all DDL/DML.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 30_000

  require Logger

  alias Restdis.Cache.Key
  alias Restdis.Cache.TenantSupervisor
  alias RestdisBuster.Infra.SlotConfig

  @tenant_id "itenant"
  @test_table "wal_int_products"
  @test_schema "public"

  setup_all do
    conn_opts = SlotConfig.replication_conn_opts()

    case Postgrex.start_link(conn_opts) do
      {:ok, conn} ->
        case verify_logical_wal(conn) do
          :ok ->
            setup_fixtures(conn)
            reset_replication_slot(conn)

            on_exit(fn ->
              # The setup_all connection is gone by the time on_exit runs.
              case Postgrex.start_link(conn_opts) do
                {:ok, c} ->
                  drop_slot(c)
                  Postgrex.query(c, "DROP TABLE IF EXISTS #{@test_schema}.#{@test_table}", [])

                  Postgrex.query(
                    c,
                    "DELETE FROM tenant_table_config WHERE tenant_id = $1 AND table_name = $2",
                    [@tenant_id, @test_table]
                  )

                  GenServer.stop(c)

                _ ->
                  :ok
              end
            end)

            {:ok, fixture_conn: conn}

          {:skip, reason} ->
            GenServer.stop(conn)
            {:skip, reason}
        end

      {:error, reason} ->
        {:skip, "Postgres not available: #{inspect(reason)}"}
    end
  end

  setup _ctx do
    TenantSupervisor.ensure_started(@tenant_id)
    Restdis.Cache.flush_tenant(@tenant_id)
    # The table-config cache is read-through; invalidate to refetch the fixture.
    RestdisBuster.TenantTableConfig.invalidate(@test_schema, @test_table)
    :ok
  end

  test "INSERT/UPDATE to tenant table invalidates matching cache entry within 2s", %{
    fixture_conn: conn
  } do
    key = Key.build(:table, @test_table, %{"id" => "eq.1"})
    value = %{"id" => 1, "name" => "seed-1"}

    Restdis.Cache.put(@tenant_id, key, value, primary_keys: [1])
    assert {:ok, ^value} = Restdis.Cache.peek(@tenant_id, key)

    {:ok, _} =
      Postgrex.query(
        conn,
        "UPDATE #{@test_schema}.#{@test_table} SET name = $1 WHERE id = 1",
        ["updated-1"]
      )

    assert wait_until(
             fn -> Restdis.Cache.peek(@tenant_id, key) == :miss end,
             2_000,
             50
           ),
           "Cache entry was not invalidated within 2s"
  end

  test "Tailer crash + restart resumes from last applied LSN (no event loss)", %{
    fixture_conn: conn
  } do
    # Make sure the row exists.
    {:ok, _} =
      Postgrex.query(
        conn,
        "INSERT INTO #{@test_schema}.#{@test_table} (id, name) VALUES (2, $1) ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name",
        ["seed-2"]
      )

    key = Key.build(:table, @test_table, %{"id" => "eq.2"})
    value = %{"id" => 2, "name" => "seed-2"}
    Restdis.Cache.put(@tenant_id, key, value, primary_keys: [2])

    {tailer_pid, _meta} = :syn.lookup(:wal, :wal_tailer)
    assert is_pid(tailer_pid)

    ref = Process.monitor(tailer_pid)
    DynamicSupervisor.terminate_child(RestdisBuster.TailerSupervisor, tailer_pid)
    assert_receive {:DOWN, ^ref, :process, ^tailer_pid, _reason}, 5_000

    # While the tailer is down, write a row update.
    {:ok, _} =
      Postgrex.query(
        conn,
        "UPDATE #{@test_schema}.#{@test_table} SET name = $1 WHERE id = 2",
        ["updated-2"]
      )

    # Singleton should bring a new tailer up.
    assert wait_until(
             fn ->
               case :syn.lookup(:wal, :wal_tailer) do
                 {pid, _} when is_pid(pid) and pid != tailer_pid -> true
                 _ -> false
               end
             end,
             5_000,
             100
           ),
           "Tailer did not restart"

    assert wait_until(
             fn -> Restdis.Cache.peek(@tenant_id, key) == :miss end,
             5_000,
             100
           ),
           "Cache entry was not invalidated after tailer restart"
  end

  # Helpers

  defp wait_until(predicate, deadline_ms, poll_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(predicate, deadline, poll_ms)
  end

  defp do_wait_until(predicate, deadline, poll_ms) do
    if predicate.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(poll_ms)
        do_wait_until(predicate, deadline, poll_ms)
      end
    end
  end

  defp verify_logical_wal(conn) do
    case Postgrex.query(conn, "SHOW wal_level", []) do
      {:ok, %Postgrex.Result{rows: [["logical"]]}} ->
        :ok

      {:ok, %Postgrex.Result{rows: [[level]]}} ->
        {:skip, "wal_level is #{inspect(level)}, need 'logical'"}

      {:error, reason} ->
        {:skip, "Could not verify wal_level: #{inspect(reason)}"}
    end
  end

  defp setup_fixtures(conn) do
    Postgrex.query!(
      conn,
      "CREATE TABLE IF NOT EXISTS #{@test_schema}.#{@test_table} (id integer PRIMARY KEY, name text)",
      []
    )

    Postgrex.query!(
      conn,
      "INSERT INTO #{@test_schema}.#{@test_table} (id, name) VALUES (1, 'seed-1') ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name",
      []
    )

    # The default REPLICA IDENTITY is enough for a table with a primary key.

    Postgrex.query!(
      conn,
      """
      INSERT INTO tenant_table_config (tenant_id, schema, table_name, mode, pk_column, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'replication', 'id', now(), now())
      ON CONFLICT (tenant_id, schema, table_name) DO UPDATE
        SET mode = EXCLUDED.mode, pk_column = EXCLUDED.pk_column, updated_at = now()
      """,
      [@tenant_id, @test_schema, @test_table]
    )

    # The publication is FOR ALL TABLES, so the test table is included.
    :ok
  end

  defp reset_replication_slot(conn) do
    # Stop the tailer so it releases the slot; the Singleton respawns it.
    case :syn.lookup(:wal, :wal_tailer) do
      {pid, _meta} when is_pid(pid) ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(RestdisBuster.TailerSupervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end

      _ ->
        :ok
    end

    drop_slot(conn)

    # Wait for the Singleton to spawn a new Tailer with the recreated slot.
    wait_until(
      fn ->
        case :syn.lookup(:wal, :wal_tailer) do
          {pid, _} when is_pid(pid) -> Process.alive?(pid)
          _ -> false
        end
      end,
      5_000,
      100
    )

    :ok
  end

  defp drop_slot(conn) do
    slot = SlotConfig.slot_name()

    case Postgrex.query(
           conn,
           "SELECT pg_drop_replication_slot($1) WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = $1)",
           [slot]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("drop_slot failed: #{inspect(reason)}")
    end
  end
end
