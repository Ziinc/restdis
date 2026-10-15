defmodule Restdis.Cache.Gossip.Transport do
  @moduledoc """
  Transport used to list peer nodes and multicast a loaded read-through entry
  to a subset of them.
  """

  @callback peers() :: [node()]
  @callback multicast(
              [node()],
              Restdis.Cache.ReadThrough.name(),
              Restdis.Cache.ReadThrough.ident(),
              term()
            ) :: :ok
end
