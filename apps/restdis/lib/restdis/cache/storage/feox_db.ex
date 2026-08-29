defmodule Restdis.Cache.Storage.FeoxDB do
  @moduledoc """
  `Restdis.Cache.Storage` backend on top of FeoxDB
  (https://github.com/mehrantsi/feoxdb), a Rust key-value store accessed
  through the `feoxdb_nif` Rustler crate under `native/feoxdb_nif`.

  Keys and values are arbitrary Erlang terms in the `Storage` behaviour, but
  the NIF only moves binaries across the boundary, so both are encoded with
  `:erlang.term_to_binary/1` and decoded with `:erlang.binary_to_term/1`.
  """

  @behaviour Restdis.Cache.Storage

  alias Restdis.Cache.Storage.FeoxDB.Native

  @impl Restdis.Cache.Storage
  def open(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    file = Path.join(data_dir, "feoxdb.store")

    case Native.open(file) do
      {:ok, resource} -> {:ok, resource}
      {:error, reason} -> raise "failed to open FeoxDB store at #{file}: #{inspect(reason)}"
    end
  end

  @impl Restdis.Cache.Storage
  def close(_resource), do: :ok

  @impl Restdis.Cache.Storage
  def fetch(resource, key) do
    case Native.get(resource, encode(key)) do
      {:ok, nil} -> :error
      {:ok, value} -> {:ok, decode(value)}
      {:error, _reason} -> :error
    end
  end

  @impl Restdis.Cache.Storage
  def put(resource, key, value) do
    :ok = Native.put(resource, encode(key), encode(value))
    :ok
  end

  @impl Restdis.Cache.Storage
  def delete(resource, key) do
    _ = Native.delete(resource, encode(key))
    :ok
  end

  @impl Restdis.Cache.Storage
  def clear(resource) do
    :ok = Native.clear(resource)
    :ok
  end

  @impl Restdis.Cache.Storage
  def select(resource) do
    resource
    |> Native.select_all()
    |> Enum.map(fn {key, value} -> {decode(key), decode(value)} end)
  end

  defp encode(term), do: :erlang.term_to_binary(term)
  defp decode(binary), do: :erlang.binary_to_term(binary)
end
