defmodule RestdisBuster.TenantTableConfig.CacheTest do
  # Exercises the DB-backed read-through path, so it can't run concurrently
  # with other tests that touch the same cache/table rows.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias RestdisBuster.TenantTableConfig.Cache
  alias RestdisRepo.TenantTableConfig, as: Schema

  setup do
    on_exit(fn ->
      RestdisRepo.delete_all(
        from(t in Schema, where: t.schema == "public" and t.table_name == "cache_test")
      )

      Cache.invalidate("public", "cache_test")
    end)

    :ok
  end

  test "cache_name/0 returns the configured cache instance name" do
    assert Cache.cache_name() == :tenant_table_config
  end

  test "lookup/2 reads through to the database and returns the config on a hit" do
    Cache.invalidate("public", "cache_test")

    %Schema{}
    |> Schema.changeset(%{
      tenant_id: "cache_test_tenant",
      schema: "public",
      table_name: "cache_test",
      mode: "ttl",
      pk_column: "id"
    })
    |> RestdisRepo.insert!()

    assert {:ok, config} = Cache.lookup("public", "cache_test")
    assert config.tenant_id == "cache_test_tenant"
    assert config.schema == "public"
    assert config.table_name == "cache_test"
    assert config.mode == "ttl"
    assert config.pk_column == "id"
  end
end
