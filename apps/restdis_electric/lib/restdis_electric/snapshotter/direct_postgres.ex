defmodule RestdisElectric.Snapshotter.DirectPostgres do
  @moduledoc """
  Snapshot reader that reads a shape's table directly from Postgres, through
  a short-lived Postgrex connection separate from the replication
  connection, instead of going through PostgREST.

  The snapshot runs inside one read-only, repeatable-read transaction: it
  records `pg_current_snapshot()` first and then pages through the table
  ordered by primary key, so every page is read under the same snapshot and
  no row is missed or duplicated across pages.

  `snapshot/3` is the extended entry point: it also returns the recorded
  `RestdisElectric.SnapshotDescriptor.t/0`, which the caller uses to decide
  whether a buffered WAL transaction is already reflected in these rows.
  `stream/3` implements `RestdisElectric.Snapshotter` by discarding the
  descriptor, so both snapshot readers share the same append path and the
  same property tests.
  """

  @behaviour RestdisElectric.Snapshotter

  alias RestdisElectric.Definition
  alias RestdisElectric.SnapshotDescriptor
  alias RestdisElectric.Snapshotter
  alias RestdisElectric.TableInfo

  @impl RestdisElectric.Snapshotter
  def stream(tenant_config, %Definition{} = definition, page_fun) do
    case snapshot(tenant_config, definition, page_fun) do
      {:ok, _descriptor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses a `postgres://user:pass@host:port/database` URL into the keyword
  options `Postgrex.start_link/1` expects.
  """
  @spec connect_opts(String.t()) :: keyword()
  def connect_opts(url) when is_binary(url) do
    uri = URI.parse(url)
    [username, password] = split_userinfo(uri.userinfo)

    [
      hostname: uri.host,
      port: uri.port,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "", "/")
    ]
  end

  defp split_userinfo(nil), do: [nil, nil]

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username, password] -> [username, password]
      [username] -> [username, nil]
    end
  end

  @doc """
  Runs the snapshot for `definition`'s table in a read-only transaction over
  `tenant_config`'s direct Postgres pool, calling `page_fun` with each page's
  rows in primary-key order, and returns the recorded snapshot descriptor.
  """
  @spec snapshot(map(), Definition.t(), ([map()] -> :ok)) ::
          {:ok, SnapshotDescriptor.t()} | {:error, term()}
  def snapshot(tenant_config, %Definition{} = definition, page_fun)
      when is_function(page_fun, 1) do
    case TableInfo.fetch(definition.schema, definition.table) do
      {:ok, info} -> run(tenant_config, definition, info, page_fun)
      :error -> {:error, {:unknown_table, Definition.qualified(definition)}}
    end
  end

  @doc """
  Records `pg_current_snapshot()` in a read-only transaction over `tenant_config`'s
  direct Postgres pool, without paging through `definition`'s table.

  Used by `log=changes_only`: the client already has every row through its own
  replica, so only the descriptor is needed, not the rows themselves.
  """
  @spec snapshot_descriptor(map(), Definition.t()) ::
          {:ok, SnapshotDescriptor.t()} | {:error, term()}
  def snapshot_descriptor(tenant_config, %Definition{} = _definition) do
    opts = connect_opts(tenant_config.direct_pg_url) ++ [pool_size: 1]

    with {:ok, conn} <- Postgrex.start_link(opts) do
      try do
        do_snapshot_descriptor(conn)
      after
        GenServer.stop(conn)
      end
    end
  end

  defp do_snapshot_descriptor(conn) do
    result =
      Postgrex.transaction(
        conn,
        fn tx ->
          Postgrex.query!(tx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])
          {:ok, descriptor} = read_descriptor(tx)
          descriptor
        end,
        []
      )

    case result do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run(tenant_config, definition, info, page_fun) do
    opts = connect_opts(tenant_config.direct_pg_url) ++ [pool_size: 1]

    with {:ok, conn} <- Postgrex.start_link(opts) do
      try do
        do_snapshot(conn, definition, info, page_fun)
      after
        GenServer.stop(conn)
      end
    end
  end

  defp do_snapshot(conn, definition, info, page_fun) do
    result =
      Postgrex.transaction(
        conn,
        fn tx ->
          Postgrex.query!(tx, "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY", [])

          {:ok, descriptor} = read_descriptor(tx)

          req = %{
            tx: tx,
            table: "#{definition.schema}.#{definition.table}",
            select: select_clause(definition.columns),
            order: Enum.join(info.primary_key, ","),
            columns: definition.columns
          }

          page(req, 0, page_fun)

          descriptor
        end,
        []
      )

    case result do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_descriptor(tx) do
    %Postgrex.Result{rows: [[text]]} =
      Postgrex.query!(tx, "SELECT pg_current_snapshot()::text", [])

    SnapshotDescriptor.parse(text)
  end

  defp select_clause(nil), do: "*"
  defp select_clause(columns), do: Enum.map_join(columns, ",", &~s("#{&1}"))

  defp page(
         %{tx: tx, table: table, select: select, order: order, columns: columns},
         offset,
         page_fun
       ) do
    page_size = Snapshotter.page_size()

    sql =
      "SELECT #{select} FROM #{table} ORDER BY #{order} LIMIT #{page_size} OFFSET #{offset}"

    %Postgrex.Result{columns: result_columns, rows: rows} = Postgrex.query!(tx, sql, [])

    if rows != [] do
      page_fun.(rows_to_maps(result_columns, rows, columns))
    end

    if length(rows) == page_size do
      page(
        %{tx: tx, table: table, select: select, order: order, columns: columns},
        offset + page_size,
        page_fun
      )
    else
      :ok
    end
  end

  defp rows_to_maps(result_columns, rows, nil) do
    Enum.map(rows, fn row -> Map.new(Enum.zip(result_columns, row)) end)
  end

  defp rows_to_maps(_result_columns, rows, columns) do
    Enum.map(rows, fn row -> Map.new(Enum.zip(columns, row)) end)
  end
end
