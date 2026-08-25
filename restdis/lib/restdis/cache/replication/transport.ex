defmodule Restdis.Cache.Replication.Transport do
  @moduledoc """
  Transport used to broadcast `persist` disk cache writes to peer nodes.
  """

  @type message :: {:sc_replication, Restdis.Cache.tenant_id(), tuple()}

  @callback broadcast(message()) :: :ok
end
