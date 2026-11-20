defmodule Restdis.Wal.InstanceConfig do
  @moduledoc """
  Per-instance configuration of a WAL follower, resolved once from the options a host
  mounts it with and read back by instance name.

  Backed by `:persistent_term`, like `Restdis.Cache.InstanceConfig`, so two followers in
  one VM never share a slot, checkpoint row or repo, and neither reads the application
  environment.
  """

  @type t :: %{
          repo: module(),
          prefix: String.t(),
          slot_name: String.t(),
          publication: String.t(),
          replication: keyword(),
          az: String.t(),
          handler: module() | nil,
          telemetry_prefix: [atom()],
          topology: :syn | :local,
          on_takeover: {module(), atom(), list()} | nil
        }

  @doc """
  Resolves and stores the config for `name` from a host's mount options.

  `:repo` is required. A `:url` inside `:replication` is expanded into Postgrex
  connection options; explicit options win over the url.
  """
  @spec put(atom(), keyword()) :: :ok
  def put(name, opts) do
    config = %{
      repo: Keyword.fetch!(opts, :repo),
      prefix: Keyword.get(opts, :prefix, Restdis.Migration.default_prefix()),
      slot_name: Keyword.get(opts, :slot_name, "restdis_slot"),
      publication: Keyword.get(opts, :publication, "restdis_pub"),
      replication: replication_opts(Keyword.get(opts, :replication, [])),
      az: Keyword.get(opts, :az, "local"),
      handler: Keyword.get(opts, :handler),
      telemetry_prefix: Keyword.get(opts, :telemetry_prefix, [:restdis]),
      topology: Keyword.get(opts, :topology, :syn),
      on_takeover: Keyword.get(opts, :on_takeover)
    }

    :persistent_term.put(key(name), config)
  end

  @doc """
  Returns the config of `name`, raising when the instance was never started.
  """
  @spec fetch!(atom()) :: t()
  def fetch!(name) do
    case :persistent_term.get(key(name), nil) do
      nil -> raise ArgumentError, "WAL follower #{inspect(name)} is not started"
      config -> config
    end
  end

  defp key(name), do: {__MODULE__, name}

  defp replication_opts(opts) do
    case Keyword.pop(opts, :url) do
      {nil, opts} -> opts
      {url, opts} -> Keyword.merge(parse_url(url), opts)
    end
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    {username, password} = userinfo(uri.userinfo)

    [
      hostname: uri.host,
      port: uri.port,
      username: username,
      password: password,
      database: database(uri.path)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [username] -> {URI.decode(username), nil}
      [username, password] -> {URI.decode(username), URI.decode(password)}
    end
  end

  defp database(nil), do: nil

  defp database(path) do
    case String.trim_leading(path, "/") do
      "" -> nil
      database -> URI.decode(database)
    end
  end
end
