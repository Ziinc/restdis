defmodule SupaCacherCache.ReadThrough do
  @moduledoc """
  Named multi-layer read-through cache: ETS query cache in front of a CubDB disk cache.

  Unlike the per-tenant aggregate, an instance is configured where it is
  supervised rather than resolved from a tenant id:

      {SupaCacherCache.ReadThrough,
       name: :tenant_config, data_dir: "./cache_data/control_plane", ttl_ms: 60_000}

  Entries are written as ordinary (non-persist) disk entries, so they survive a
  process restart without consuming a tenant persist cap. Every entry carries the
  instance TTL in both layers.
  """

  use Supervisor

  alias SupaCacherCache.DiskCache
  alias SupaCacherCache.QueryCache

  @type name :: atom()
  @type key :: term()

  @default_ttl_ms 60_000

  @doc """
  Returns the child spec of the cache instance named in `opts`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @doc """
  Starts the cache instance with the `:name`, `:data_dir` and `:ttl_ms` in `opts`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(name))
  end

  @doc """
  Returns the cache-layer namespace of the instance `name`.
  """
  @spec namespace(name()) :: String.t()
  def namespace(name), do: "read_through/#{name}"

  @doc """
  Reads `key`, calling `loader` on a miss and caching only its `{:ok, value}`.
  """
  @spec fetch(name(), key(), (-> {:ok, term()} | term())) :: {:ok, term()} | term()
  def fetch(name, key, loader) when is_function(loader, 0) do
    %{namespace: ns, ttl_ms: ttl_ms} = config(name)

    with :miss <- QueryCache.get(ns, key),
         :miss <- disk_get_and_promote(ns, key, ttl_ms) do
      load(name, key, loader)
    end
  end

  @doc """
  Writes `value` under `key` into every layer.
  """
  @spec put(name(), key(), term()) :: :ok
  def put(name, key, value) do
    %{namespace: ns, ttl_ms: ttl_ms} = config(name)
    QueryCache.put(ns, key, value, ttl_ms: ttl_ms)
    DiskCache.put(ns, key, envelope(value, ttl_ms))
    :ok
  end

  @doc """
  Removes `key` from every layer.
  """
  @spec delete(name(), key()) :: :ok
  def delete(name, key) do
    ns = config(name).namespace
    QueryCache.delete(ns, key)
    DiskCache.delete(ns, key)
    :ok
  end

  @doc """
  Removes every entry from every layer.
  """
  @spec flush(name()) :: :ok
  def flush(name) do
    ns = config(name).namespace
    QueryCache.flush(ns)
    DiskCache.flush(ns)
    :ok
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    data_dir = Keyword.fetch!(opts, :data_dir)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    ns = namespace(name)

    :persistent_term.put({:sc_rt, name}, %{namespace: ns, ttl_ms: ttl_ms})

    children = [
      QueryCache.child_spec(ns),
      {DiskCache, tenant_id: ns, data_dir: data_dir}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp load(name, key, loader) do
    case loader.() do
      {:ok, value} ->
        put(name, key, value)
        {:ok, value}

      other ->
        other
    end
  end

  defp disk_get_and_promote(ns, key, ttl_ms) do
    case DiskCache.get(ns, key) do
      {:ok, {:rt, value, expires_at}} ->
        if expires_at > now_ms() do
          QueryCache.put(ns, key, value, ttl_ms: ttl_ms)
          {:ok, value}
        else
          DiskCache.delete(ns, key)
          :miss
        end

      _ ->
        :miss
    end
  end

  defp envelope(value, ttl_ms), do: {:rt, value, now_ms() + ttl_ms}

  defp now_ms, do: System.system_time(:millisecond)

  defp config(name) do
    case :persistent_term.get({:sc_rt, name}, nil) do
      nil -> raise ArgumentError, "read-through cache #{inspect(name)} is not started"
      config -> config
    end
  end

  defp supervisor_name(name), do: :"#{__MODULE__}.#{name}"
end
