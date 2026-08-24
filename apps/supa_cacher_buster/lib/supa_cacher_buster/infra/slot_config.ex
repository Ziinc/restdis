defmodule SupaCacherBuster.Infra.SlotConfig do
  @moduledoc false

  @doc """
  Returns the configured replication slot name.
  """
  @spec slot_name() :: String.t()
  def slot_name do
    Application.get_env(:supa_cacher_buster, :slot_name, "supacacher_slot")
  end

  @doc """
  Returns the configured publication name.
  """
  @spec publication_name() :: String.t()
  def publication_name do
    Application.get_env(:supa_cacher_buster, :publication_name, "supacacher_pub")
  end

  @doc """
  Returns this node's availability zone, used as the fanout topic scope.
  """
  @spec az() :: String.t()
  def az do
    Application.get_env(:supa_cacher_buster, :az, "local")
  end

  @doc """
  Returns the connection options for the replication connection.
  """
  @spec replication_conn_opts() :: keyword()
  def replication_conn_opts do
    opts = Application.get_env(:supa_cacher_buster, :replication_connection, [])

    case Keyword.pop(opts, :url) do
      {nil, opts} -> opts
      {url, opts} -> Keyword.merge(parse_url(url), opts)
    end
  end

  @spec parse_url(String.t()) :: keyword()
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
