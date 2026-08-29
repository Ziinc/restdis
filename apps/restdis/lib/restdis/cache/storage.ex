defmodule Restdis.Cache.Storage do
  @moduledoc """
  Behaviour implemented by pluggable disk-storage backends for `Restdis.Cache.DiskCache`.

  A backend owns a single tenant's on-disk store. Implementations must be
  safe to call from the `DiskCache` GenServer that owns the handle; no
  concurrent access from multiple processes is required.

  The backend in use is selected via `:restdis, :storage_backend` (defaults
  to `Restdis.Cache.Storage.CubDB`), so both backends can be run side by
  side (e.g. one per tenant, or for benchmarking) without code changes.
  """

  @type handle :: term()
  @type key :: term()
  @type value :: term()

  @doc "Opens (creating if absent) the store rooted at `opts[:data_dir]`."
  @callback open(opts :: keyword()) :: {:ok, handle()}

  @doc "Closes a previously opened handle, releasing any resources."
  @callback close(handle()) :: :ok

  @doc "Fetches the value stored under `key`."
  @callback fetch(handle(), key()) :: {:ok, value()} | :error

  @doc "Stores `value` under `key`, overwriting any existing entry."
  @callback put(handle(), key(), value()) :: :ok

  @doc "Removes `key`, if present."
  @callback delete(handle(), key()) :: :ok

  @doc "Removes every entry from the store."
  @callback clear(handle()) :: :ok

  @doc "Returns a `{key, value}` enumerable of every entry in the store."
  @callback select(handle()) :: Enumerable.t()

  @doc """
  Returns the configured storage backend module.

  Reads `:restdis, :storage_backend` at call time (not compile time) so
  tests and benchmarks can switch backends per-run.
  """
  @spec backend() :: module()
  def backend do
    Application.get_env(:restdis, :storage_backend, Restdis.Cache.Storage.CubDB)
  end
end
