defmodule RestdisServer.HTTP.Plug.AuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias RestdisServer.HTTP.Plug.Auth
  alias RestdisServer.TenantConfig
  alias RestdisServer.TenantStore.InMemory

  setup do
    InMemory.seed([
      %{
        api_key: "plug_scoped",
        key_pgrst_api_key: "plug_scoped_jwt",
        tenant_id: "plug-auth-tenant",
        default_ttl_s: 60,
        persist_cap: 10,
        pgrst_base_url: "http://localhost:3000",
        pgrst_api_key: "plug_tenant_key",
        replica_url: nil
      }
    ])

    TenantConfig.invalidate("plug-auth-tenant")
    on_exit(fn -> InMemory.clear() end)
    :ok
  end

  test "init/1 returns opts unchanged" do
    assert Auth.init(:opts) == :opts
  end

  test "assigns the API key's effective upstream credential" do
    conn =
      conn(:get, "/")
      |> put_req_header("authorization", "Bearer plug_scoped")
      |> Auth.call([])

    refute conn.halted
    assert conn.assigns.tenant_id == "plug-auth-tenant"
    assert conn.assigns.pgrst_credential == "plug_scoped_jwt"
  end
end
