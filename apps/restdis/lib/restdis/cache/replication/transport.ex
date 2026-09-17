defmodule Restdis.Cache.Replication.Transport do
  @moduledoc """
  Transport used to broadcast `persist` disk cache writes to peer nodes.
  """

  @type message :: {:sc_replication, atom(), Restdis.Cache.tenant_id(), tuple()}

  @callback broadcast(receiver_name :: atom(), message()) :: :ok
end
