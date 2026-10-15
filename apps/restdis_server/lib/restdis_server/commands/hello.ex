defmodule RestdisServer.Commands.Hello do
  @moduledoc """
  Handles the RESP `HELLO` command.

  Restdis speaks RESP2 only. A client asking for RESP3 gets `NOPROTO`, which
  clients such as ioredis and redis-py treat as the signal to fall back to
  RESP2 and a plain `AUTH`. `HELLO 2 AUTH <username> <api_key>` authenticates
  the same way `AUTH <api_key>` does; the username is ignored.
  """

  alias RestdisServer.Commands.Auth
  alias RestdisServer.RESP.Encoder

  @doc """
  Negotiates the protocol version, optionally authenticates, and replies with
  the server info as a flat RESP2 array.
  """
  @spec run(map(), [binary()]) :: {iodata(), map()}
  def run(state, []), do: reply(state, [])

  def run(state, [protover | opts]) do
    case Integer.parse(protover) do
      {2, ""} ->
        reply(state, opts)

      {_other, ""} ->
        {Encoder.error("NOPROTO sorry, this protocol version is not supported"), state}

      _ ->
        {Encoder.error("ERR Protocol version is not an integer or out of range"), state}
    end
  end

  defp reply(state, opts) do
    with {:ok, state} <- apply_options(state, opts),
         :ok <- ensure_authenticated(state) do
      {Encoder.array(server_info()), state}
    else
      {:error, error, state} -> {error, state}
    end
  end

  defp apply_options(state, []), do: {:ok, state}

  defp apply_options(state, [opt | rest]) do
    case {String.upcase(opt), rest} do
      {"AUTH", [_username, api_key | rest]} -> authenticate(state, api_key, rest)
      {"SETNAME", [_name | rest]} -> apply_options(state, rest)
      _ -> {:error, Encoder.error("ERR Syntax error in HELLO option '#{opt}'"), state}
    end
  end

  defp authenticate(state, api_key, rest) do
    case Auth.authenticate(state, api_key) do
      {:ok, authed} -> apply_options(authed, rest)
      {:error, error} -> {:error, error, state}
    end
  end

  defp ensure_authenticated(%{authenticated?: true}), do: :ok

  defp ensure_authenticated(state) do
    {:error,
     Encoder.error(
       "NOAUTH HELLO must be called with the client already authenticated, otherwise the HELLO <proto> AUTH <user> <pass> option can be used to authenticate the client and select the RESP protocol version at the same time"
     ), state}
  end

  defp server_info do
    version = :restdis_server |> Application.spec(:vsn) |> to_string()

    [
      "server",
      "restdis",
      "version",
      version,
      "proto",
      2,
      "id",
      :erlang.phash2(self()),
      "mode",
      "standalone",
      "role",
      "master",
      "modules",
      []
    ]
  end
end
