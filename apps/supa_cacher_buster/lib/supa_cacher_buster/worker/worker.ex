defmodule SupaCacherBuster.Worker do
  @moduledoc """
  Per-event worker that invalidates or refreshes the cache entries affected by a WAL event.
  """

  use Task, restart: :temporary

  alias SupaCacherBuster.Infra.LsnStore
  alias SupaCacherBuster.TenantTableConfig
  alias SupaCacherBuster.WAL.Event

  @infra_schema "public"
  @tenants_table "tenants"
  @table_config_table "tenant_table_config"

  def start_link(%Event{} = event) do
    Task.start_link(__MODULE__, :run, [event])
  end

  defp ack(%Event{lsn: nil}), do: :ok
  defp ack(%Event{lsn: lsn}), do: LsnStore.applied(lsn)

  @spec run(Event.t()) :: :ok
  def run(%Event{op: op, schema: @infra_schema, table: @tenants_table} = event)
      when op in [:insert, :update, :delete] do
    row = event.new_row || event.old_row || %{}
    tenant_id = Map.get(row, "tenant_id")

    if tenant_id do
      invalidator = Application.get_env(:supa_cacher_buster, :tenant_config_invalidator)
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
      SupaCacherCache.flush_table(tenant_id, table_name)
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
          [:supa_cacher_buster, :event, :processed],
          %{count: 1, duration_us: elapsed_us(event.received_at)},
          %{op: op, schema: event.schema, table: event.table}
        )

        SupaCacherCache.invalidate_by_row(config.tenant_id, event.table, pk)

        :telemetry.execute(
          [:supa_cacher_buster, :invalidation, :latency],
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
      SupaCacherCache.flush_table(config.tenant_id, event.table)

      :telemetry.execute(
        [:supa_cacher_buster, :invalidation, :latency],
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

  defp handle_ddl_message(%{prefix: "supacacher_ddl", content: content}) do
    case Jason.decode(content) do
      {:ok, %{"op" => "drop", "schema" => schema, "table" => table}} ->
        case TenantTableConfig.lookup(schema, table) do
          {:ok, config} -> SupaCacherCache.flush_table(config.tenant_id, table)
          :not_found -> :ok
        end

      _ ->
        :ok
    end
  end

  defp handle_ddl_message(_), do: :ok

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
