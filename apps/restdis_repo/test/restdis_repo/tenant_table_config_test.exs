defmodule RestdisRepo.TenantTableConfigTest do
  use ExUnit.Case, async: true

  alias RestdisRepo.TenantTableConfig

  @valid_attrs %{tenant_id: "acme", table_name: "orders"}

  test "changeset is valid with required attrs" do
    changeset = TenantTableConfig.changeset(%TenantTableConfig{}, @valid_attrs)
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :schema) == "public"
    assert Ecto.Changeset.get_field(changeset, :mode) == "ttl"
    assert Ecto.Changeset.get_field(changeset, :pk_column) == "id"
  end

  test "changeset requires tenant_id, schema and table_name" do
    changeset = TenantTableConfig.changeset(%TenantTableConfig{}, %{})

    refute changeset.valid?
  end

  test "changeset rejects an unknown mode" do
    changeset =
      TenantTableConfig.changeset(%TenantTableConfig{}, Map.put(@valid_attrs, :mode, "bogus"))

    refute changeset.valid?
  end

  test "changeset accepts the replication mode and a filter" do
    attrs = Map.merge(@valid_attrs, %{mode: "replication", filter: "status = 'open'"})
    changeset = TenantTableConfig.changeset(%TenantTableConfig{}, attrs)

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :filter) == "status = 'open'"
  end
end
