defmodule Restdis.Cache.Storage.CubDB do
  @moduledoc """
  `Restdis.Cache.Storage` backend on top of CubDB, a pure-Elixir embedded
  ordered key-value store.
  """

  @behaviour Restdis.Cache.Storage

  @impl Restdis.Cache.Storage
  def open(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    CubDB.start_link(data_dir: data_dir)
  end

  @impl Restdis.Cache.Storage
  def close(cubdb), do: CubDB.stop(cubdb)

  @impl Restdis.Cache.Storage
  def fetch(cubdb, key), do: CubDB.fetch(cubdb, key)

  @impl Restdis.Cache.Storage
  def put(cubdb, key, value), do: CubDB.put(cubdb, key, value)

  @impl Restdis.Cache.Storage
  def delete(cubdb, key), do: CubDB.delete(cubdb, key)

  @impl Restdis.Cache.Storage
  def clear(cubdb), do: CubDB.clear(cubdb)

  @impl Restdis.Cache.Storage
  def select(cubdb), do: CubDB.select(cubdb)
end
