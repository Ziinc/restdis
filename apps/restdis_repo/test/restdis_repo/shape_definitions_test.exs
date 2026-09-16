defmodule RestdisRepo.ShapeDefinitionsTest do
  use ExUnit.Case, async: true

  alias RestdisRepo.ShapeDefinitions

  @valid_attrs %{tenant_id: "acme", name: "orders", table: "orders"}

  test "changeset is valid with required attrs" do
    changeset = ShapeDefinitions.changeset(%ShapeDefinitions{}, @valid_attrs)
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :replica) == "default"
  end

  test "changeset requires tenant_id, name and table" do
    changeset = ShapeDefinitions.changeset(%ShapeDefinitions{}, %{})

    refute changeset.valid?
  end

  test "changeset rejects an unknown replica" do
    changeset =
      ShapeDefinitions.changeset(%ShapeDefinitions{}, Map.put(@valid_attrs, :replica, "bogus"))

    refute changeset.valid?
  end

  test "changeset accepts the full replica" do
    changeset =
      ShapeDefinitions.changeset(%ShapeDefinitions{}, Map.put(@valid_attrs, :replica, "full"))

    assert changeset.valid?
  end

  test "changeset accepts a where clause and columns" do
    attrs = Map.merge(@valid_attrs, %{where: "status = 'open'", columns: ["id", "status"]})
    changeset = ShapeDefinitions.changeset(%ShapeDefinitions{}, attrs)

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :columns) == ["id", "status"]
  end
end
