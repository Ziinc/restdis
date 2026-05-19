defmodule SupaCacherCache.Origin do
  @callback fetch(tenant_id :: String.t(), SupaCacherCache.Key.t()) :: {:ok, term()} | :error
end
