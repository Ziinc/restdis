defmodule RestdisBuster.Worker do
  @moduledoc """
  Per-event worker that invalidates or refreshes the cache entries affected by a WAL event.
  """

  use Task, restart: :temporary

  alias RestdisBuster.Infra.LsnStore
  alias RestdisBuster.TenantTableConfig
  alias RestdisBuster.WAL.Event
  alias RestdisBuster.Worker.HandlerConfig
  alias RestdisElectric.TableInfo
  alias RestdisElectric.WAL, as: ElectricWAL

  @infra_schema "public"
  @tenants_table "tenants"
  @table_config_table "tenant_table_config"

  @doc """
  Starts a worker task for `event`.
  """
  @spec start_link(Event.t()) :: {:ok, pid()}
  def start_link(%Event{} = event) do
    Task.start_link(__MODULE__, :run, [event])
  end

  defp ack(%Event{lsn: nil}), do: :ok
  defp ack(%Event{lsn: lsn}), do: LsnStore.applied(lsn)

  @doc """
  Applies `event` to the cache, then acknowledges its LSN.
  """
  @spec run(Event.t()) :: :ok
  def run(%Event{op: op, schema: @infra_schema, table: @tenants_table} = event)
      when op in [:insert, :update, :delete] do
    row = event.new_row || event.old_row || %{}
    tenant_id = Map.get(row, "tenant_id")

    if tenant_id do
      invalidator = Application.get_env(:restdis_buster, :tenant_config_invalidator)
      if invalidator, do: invalidator.invalidate(tenant_id)
    end

    ack(event)
    :ok
  end

  def run(%Event{op: op, schema: @infra_schema, table: @table_config_table} = event)
      when op in [:insert, :update, :delete] do
    row = event.new_row || event.old_row || %{}
    schema = Map.get(row, "schema", @infra_schema)
    table_name = Map.get(row, "table_name")
    tenant_id = Map.get(row, "tenant_id")

    if table_name && tenant_id do
      TenantTableConfig.invalidate(schema, table_name)
      handler().flush_table(tenant_id, table_name)
    end

    ack(event)
    :ok
  end

  def run(%Event{op: op} = event) when op in [:insert, :update, :delete] do
    with {:ok, config} <- TenantTableConfig.lookup(event.schema, event.table) do
      row = event.new_row || event.old_row || %{}
      pk_str = Map.get(row, config.pk_column)

      if pk_str do
        pk = coerce_pk(pk_str)

        :telemetry.execute(
          [:restdis_buster, :event, :processed],
          %{count: 1, duration_us: elapsed_us(event.received_at)},
          %{op: op, schema: event.schema, table: event.table}
        )

        apply_change(config, event, row, pk)
        ingest_shape_change(config, event, pk)

        :telemetry.execute(
          [:restdis_buster, :invalidation, :latency],
          %{duration_us: elapsed_us(event.received_at)},
          %{tenant_id: config.tenant_id, table: event.table, op: event.op}
        )
      end
    end

    ack(event)
    :ok
  end

  def run(%Event{op: :truncate} = event) do
    with {:ok, config} <- TenantTableConfig.lookup(event.schema, event.table) do
      handler().flush_table(config.tenant_id, event.table)

      :telemetry.execute(
        [:restdis_buster, :invalidation, :latency],
        %{duration_us: elapsed_us(event.received_at)},
        %{tenant_id: config.tenant_id, table: event.table, op: event.op}
      )
    end

    ack(event)
    :ok
  end

  def run(%Event{op: :message} = event) do
    handle_ddl_message(event.new_row)
    ack(event)
    :ok
  end

  def run(_event), do: :ok

  defp handle_ddl_message(%{prefix: "restdis_ddl", content: content}) do
    case Jason.decode(content) do
      {:ok, %{"op" => "drop", "schema" => schema, "table" => table}} ->
        case TenantTableConfig.lookup(schema, table) do
          {:ok, config} -> handler().flush_table(config.tenant_id, table)
          :not_found -> :ok
        end

      _ ->
        :ok
    end
  end

  defp handle_ddl_message(_), do: :ok

  # pgoutput discards type OIDs while decoding, so every value here is text; cast it back to a real type.
  defp ingest_shape_change(config, event, pk) do
    types = table_types(event.schema, event.table)

    ElectricWAL.ingest(%{
      tenant_id: config.tenant_id,
      schema: event.schema,
      table: event.table,
      op: event.op,
      pk: pk,
      new_row: cast_row(event.new_row, types),
      old_row: cast_row(event.old_row, types),
      lsn: event.lsn
    })
  end

  defp table_types(schema, table) do
    case TableInfo.fetch(schema, table) do
      {:ok, %{types: types}} -> types
      :error -> %{}
    end
  end

  defp cast_row(nil, _types), do: nil

  defp cast_row(row, types),
    do: Map.new(row, fn {col, val} -> {col, cast_value(val, Map.get(types, col))} end)

  defp cast_value(val, type) when is_binary(val) and is_binary(type) do
    cond do
      integer_type?(type) -> parse_integer(val)
      boolean_type?(type) -> parse_boolean(val)
      float_type?(type) -> parse_float(val)
      true -> val
    end
  end

  defp cast_value(val, _type), do: val

  defp integer_type?(type), do: String.starts_with?(type, ["smallint", "integer", "bigint"])
  defp boolean_type?(type), do: type == "boolean"
  defp float_type?(type), do: String.starts_with?(type, ["real", "double precision", "numeric"])

  defp parse_integer(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _ -> val
    end
  end

  defp parse_float(val) do
    case Float.parse(val) do
      {f, ""} -> f
      _ -> val
    end
  end

  defp parse_boolean("t"), do: true
  defp parse_boolean("f"), do: false
  defp parse_boolean(val), do: val

  defp apply_change(%{mode: "replication"} = config, event, row, _pk) do
    case Application.get_env(:restdis_buster, :replication_dispatcher) do
      nil -> :ok
      dispatcher -> dispatcher.dispatch(config, event.op, row)
    end
  end

  defp apply_change(config, %Event{op: :insert} = event, _row, _pk) do
    handler().invalidate_lists(config.tenant_id, event.table)
  end

  defp apply_change(config, event, _row, pk) do
    handler().invalidate_by_row(config.tenant_id, event.table, pk)
  end

  defp handler, do: HandlerConfig.handler()

  defp elapsed_us(nil), do: 0

  defp elapsed_us(received_at) when is_integer(received_at) do
    System.monotonic_time(:microsecond) - received_at
  end

  defp coerce_pk(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp coerce_pk(value), do: value
end
