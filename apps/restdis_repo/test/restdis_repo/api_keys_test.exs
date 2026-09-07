defmodule RestdisRepo.ApiKeysTest do
  use ExUnit.Case, async: true

  alias RestdisRepo.ApiKeys

  test "changeset is valid with required attrs" do
    changeset = ApiKeys.changeset(%ApiKeys{}, %{api_key: "key-1", tenant_id: "acme"})
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "active"
  end

  test "changeset requires api_key and tenant_id" do
    changeset = ApiKeys.changeset(%ApiKeys{}, %{})

    refute changeset.valid?
  end

  test "changeset rejects an unknown status" do
    changeset =
      ApiKeys.changeset(%ApiKeys{}, %{api_key: "key-1", tenant_id: "acme", status: "bogus"})

    refute changeset.valid?
  end

  test "changeset accepts a revoked status" do
    changeset =
      ApiKeys.changeset(%ApiKeys{}, %{api_key: "key-1", tenant_id: "acme", status: "revoked"})

    assert changeset.valid?
  end
end
