defmodule SupaCacherReplicator.Dataset do
  @moduledoc """
  Domain struct describing a replicated table and the cache keys of its rows.
  """

  alias SupaCacherCache.Key

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          schema: String.t(),
          table: String.t(),
          pk_column: String.t(),
          filter: String.t() | nil
        }

  defstruct [:tenant_id, :schema, :table, :pk_column, :filter]

  @pk_param "__replicated_pk"

  @doc """
  Builds a dataset from a tenant table configuration map.
  """
  @spec new(map()) :: t()
  def new(%__MODULE__{} = dataset), do: dataset

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      tenant_id: fetch(attrs, :tenant_id),
      schema: fetch(attrs, :schema) || "public",
      table: fetch(attrs, :table_name) || fetch(attrs, :table),
      pk_column: fetch(attrs, :pk_column) || "id",
      filter: fetch(attrs, :filter)
    }
  end

  @doc """
  Returns the cache key holding the row of `table` with primary key `pk`.
  """
  @spec cache_key(t() | String.t(), term()) :: Key.t()
  def cache_key(%__MODULE__{table: table}, pk), do: cache_key(table, pk)

  def cache_key(table, pk) when is_binary(table) do
    Key.build(:table, table, %{@pk_param => to_string(pk)})
  end

  @doc """
  Splits a Redis `<table>:<primary_key>` key into its parts.
  """
  @spec parse_wire_key(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_wire_key("pgrst:" <> _rest), do: :error

  def parse_wire_key(wire_key) when is_binary(wire_key) do
    case String.split(wire_key, ":", parts: 2) do
      [table, pk] when table != "" and pk != "" -> {:ok, {table, pk}}
      _ -> :error
    end
  end

  def parse_wire_key(_wire_key), do: :error

  @doc """
  Returns the primary key of `row` as a string, or nil when absent.
  """
  @spec pk_of(t(), map()) :: String.t() | nil
  def pk_of(%__MODULE__{pk_column: pk_column}, row) when is_map(row) do
    case Map.fetch(row, pk_column) do
      {:ok, nil} -> nil
      {:ok, pk} -> to_string(pk)
      :error -> nil
    end
  end

  def pk_of(_dataset, _row), do: nil

  @doc """
  Returns the registry key identifying the subscription of `dataset`.
  """
  @spec registry_key(t()) :: {String.t(), String.t(), String.t()}
  def registry_key(%__MODULE__{} = dataset) do
    {dataset.tenant_id, dataset.schema, dataset.table}
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end
