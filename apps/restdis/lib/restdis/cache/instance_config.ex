defmodule Restdis.Cache.InstanceConfig do
  @moduledoc """
  Per-instance mount configuration, resolved once at `Restdis.Cache.Supervisor.start_link/1`
  and read back by instance name (the `:name` passed to `start_link/1`, defaulting to
  `Restdis.Cache`).

  Backed by `:persistent_term`, the same mechanism `Restdis.Cache.Cluster` already uses
  for its hash ring, so two mounted instances never read or write each other's config and
  neither reads the `:restdis` application environment.
  """

  @default_ets_cap_bytes 500 * 1024 * 1024
  @default_cubdb_cap_bytes 500 * 1024 * 1024
  @default_persist_cap 50_000
  @default_prefix "restdis"

  @type t :: %{
          repo: module() | nil,
          prefix: String.t(),
          data_dir: String.t(),
          origin: module() | nil,
          replication_transport: module(),
          ets_cap_bytes: pos_integer(),
          cubdb_cap_bytes: pos_integer(),
          persist_cap: pos_integer()
        }

  @doc """
  Resolves and stores the config for `name` from the `opts` given to `start_link/1`.
  """
  @spec put(atom(), keyword()) :: :ok
  def put(name, opts) do
    config = %{
      repo: Keyword.get(opts, :repo),
      prefix: Keyword.get(opts, :prefix, @default_prefix),
      data_dir: Keyword.get(opts, :data_dir, "./cache_data"),
      origin: Keyword.get(opts, :origin),
      replication_transport:
        Keyword.get(
          opts,
          :replication_transport,
          Restdis.Cache.Replication.Transport.Distribution
        ),
      ets_cap_bytes: Keyword.get(opts, :ets_cap_bytes, @default_ets_cap_bytes),
      cubdb_cap_bytes: Keyword.get(opts, :cubdb_cap_bytes, @default_cubdb_cap_bytes),
      persist_cap: Keyword.get(opts, :persist_cap, @default_persist_cap)
    }

    :persistent_term.put(key(name), config)
  end

  @doc """
  Returns the config of `name`, raising when the instance was never started.
  """
  @spec fetch!(atom()) :: t()
  def fetch!(name) do
    case :persistent_term.get(key(name), nil) do
      nil -> raise ArgumentError, "cache instance #{inspect(name)} is not started"
      config -> config
    end
  end

  @doc """
  Overrides a single `field` of `name`'s already-started config, e.g. to tune a
  resource cap at runtime. Raises when the instance was never started.
  """
  @spec put_field(atom(), atom(), term()) :: :ok
  def put_field(name, field, value) do
    config = name |> fetch!() |> Map.put(field, value)
    :persistent_term.put(key(name), config)
  end

  @doc """
  Returns `field` of `name`'s config, or `default` when the instance has no config
  (e.g. a `Restdis.Cache.ReadThrough` instance, which is not mounted through
  `Restdis.Cache.Supervisor` and never calls `put/2`).
  """
  @spec get(atom(), atom(), term()) :: term()
  def get(name, field, default \\ nil) do
    case :persistent_term.get(key(name), nil) do
      nil -> default
      config -> Map.get(config, field, default)
    end
  end

  defp key(name), do: {__MODULE__, name}
end
