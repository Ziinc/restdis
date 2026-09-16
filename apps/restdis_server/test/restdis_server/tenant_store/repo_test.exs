defmodule RestdisServer.TenantStore.RepoTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias RestdisRepo.ApiKeys
  alias RestdisRepo.ShapeDefinitions
  alias RestdisRepo.Tenants
  alias RestdisServer.TenantStore.Repo, as: TenantStoreRepo

  setup do
    owner = Sandbox.start_owner!(RestdisRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  defp tenant_id, do: "tenant_store_repo_#{System.unique_integer([:positive])}"

  defp insert_tenant!(tenant_id, attrs \\ %{}) do
    %Tenants{}
    |> Tenants.changeset(
      Map.merge(
        %{
          tenant_id: tenant_id,
          pgrst_base_url: "https://pgrst.example.com",
          pgrst_api_key: "secret"
        },
        attrs
      )
    )
    |> RestdisRepo.insert!()
  end

  defp insert_api_key!(api_key, tenant_id, attrs \\ %{}) do
    %ApiKeys{}
    |> ApiKeys.changeset(Map.merge(%{api_key: api_key, tenant_id: tenant_id}, attrs))
    |> RestdisRepo.insert!()
  end

  defp insert_shape!(tenant_id, name, attrs) do
    %ShapeDefinitions{}
    |> ShapeDefinitions.changeset(
      Map.merge(%{tenant_id: tenant_id, name: name, table: "widgets"}, attrs)
    )
    |> RestdisRepo.insert!()
  end

  describe "fetch_by_api_key/1" do
    test "returns the tenant configuration for an active key" do
      tenant_id = tenant_id()
      insert_tenant!(tenant_id)
      insert_api_key!("key-#{tenant_id}", tenant_id)

      assert {:ok, config} = TenantStoreRepo.fetch_by_api_key("key-#{tenant_id}")
      assert config.tenant_id == tenant_id
      assert config.pgrst_base_url == "https://pgrst.example.com"
      assert config.shapes == %{}
    end

    test "does not return a revoked key" do
      tenant_id = tenant_id()
      insert_tenant!(tenant_id)
      insert_api_key!("key-#{tenant_id}", tenant_id, %{status: "revoked"})

      assert {:error, :not_found} = TenantStoreRepo.fetch_by_api_key("key-#{tenant_id}")
    end

    test "returns not_found for an unknown key" do
      assert {:error, :not_found} = TenantStoreRepo.fetch_by_api_key("nonexistent-key")
    end
  end

  describe "fetch_by_tenant/1" do
    test "returns the tenant configuration including named shapes" do
      tenant_id = tenant_id()

      insert_tenant!(tenant_id, %{
        default_ttl_s: 30,
        max_shapes: 5,
        allow_shape_deletion: true
      })

      insert_shape!(tenant_id, "active_widgets", %{where: "status=eq.active", columns: ["id"]})

      assert {:ok, config} = TenantStoreRepo.fetch_by_tenant(tenant_id)
      assert config.tenant_id == tenant_id
      assert config.default_ttl_s == 30
      assert config.max_shapes == 5
      assert config.allow_shape_deletion == true

      assert config.shapes == %{
               "active_widgets" => %{
                 table: "widgets",
                 where: "status=eq.active",
                 columns: ["id"],
                 replica: "default"
               }
             }
    end

    test "returns not_found for an unknown tenant" do
      assert {:error, :not_found} = TenantStoreRepo.fetch_by_tenant("nonexistent-tenant")
    end
  end

  describe "list_all/0" do
    test "returns every tenant configuration" do
      tenant_id = tenant_id()
      insert_tenant!(tenant_id)

      configs = TenantStoreRepo.list_all()
      assert Enum.any?(configs, &(&1.tenant_id == tenant_id))
    end
  end
end
