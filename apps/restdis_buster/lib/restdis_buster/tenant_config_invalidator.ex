defmodule RestdisBuster.TenantConfigInvalidator do
  @moduledoc false

  @callback invalidate(tenant_id :: String.t()) :: :ok
end
