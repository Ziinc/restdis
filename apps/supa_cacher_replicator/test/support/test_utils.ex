defmodule SupaCacherReplicator.TestUtils do
  @moduledoc """
  Shared test helpers for the `supa_cacher_replicator` bounded context.
  """

  alias SupaCacherReplicator.Dataset
  alias SupaCacherReplicator.Origin.Stub

  @doc """
  Builds a dataset with a unique tenant and table name.
  """
  @spec dataset(keyword()) :: Dataset.t()
  def dataset(opts \\ []) do
    unique = System.unique_integer([:positive])

    Dataset.new(%{
      tenant_id: Keyword.get(opts, :tenant_id, "tenant_#{unique}"),
      schema: "public",
      table_name: Keyword.get(opts, :table, "products_#{unique}"),
      pk_column: Keyword.get(opts, :pk_column, "id"),
      filter: Keyword.get(opts, :filter)
    })
  end

  @doc """
  Builds `count` rows keyed by the dataset primary key column.
  """
  @spec rows(Dataset.t(), pos_integer()) :: [map()]
  def rows(%Dataset{pk_column: pk_column}, count) do
    Enum.map(1..count, fn i -> %{pk_column => i, "name" => "row-#{i}"} end)
  end

  @doc """
  Seeds the stub origin and removes the dataset's cache and stub state on exit.
  """
  @spec seed(Dataset.t(), [map()]) :: :ok
  def seed(%Dataset{} = dataset, rows) do
    Stub.seed(dataset, rows)
    :ok
  end

  @doc """
  Stops the subscription and drops every cache entry of `dataset`.
  """
  @spec cleanup(Dataset.t()) :: :ok
  def cleanup(%Dataset{} = dataset) do
    SupaCacherReplicator.unsubscribe(dataset)
    Stub.clear(dataset)
    Restdis.Cache.flush_tenant(dataset.tenant_id)
    :ok
  end
end
