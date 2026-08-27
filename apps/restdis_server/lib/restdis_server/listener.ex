defmodule RestdisServer.Listener do
  @moduledoc false

  @doc false
  @spec parse_ip(:inet.ip_address() | atom() | String.t()) :: :inet.ip_address() | atom()
  def parse_ip(ip) when is_atom(ip) or is_tuple(ip), do: ip

  def parse_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> address
      {:error, _reason} -> :loopback
    end
  end
end
