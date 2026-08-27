defmodule RestdisBuster.CompositeInvalidator do
  @moduledoc false

  @behaviour RestdisBuster.TenantConfigInvalidator

  require Logger

  @impl RestdisBuster.TenantConfigInvalidator
  @spec invalidate(String.t()) :: :ok
  def invalidate(tenant_id) do
    chain = Application.get_env(:restdis_buster, :tenant_config_invalidator_chain, [])

    Enum.each(chain, fn impl ->
      try do
        impl.invalidate(tenant_id)
      catch
        kind, reason ->
          Logger.warning(
            "tenant_config_invalidator #{inspect(impl)} failed for #{inspect(tenant_id)}: #{inspect(kind)} #{inspect(reason)}"
          )
      end
    end)

    :ok
  end
end
