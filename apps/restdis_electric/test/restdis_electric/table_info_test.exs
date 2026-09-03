defmodule RestdisElectric.TableInfoTest do
  use ExUnit.Case, async: false

  alias RestdisElectric.TableInfo
  alias RestdisElectric.TestUtils

  test "fetch/2 returns :error for an unconfigured table" do
    assert :error = TableInfo.fetch("public", "does_not_exist")
  end

  test "fetch/2 returns the configured schema" do
    TestUtils.put_table("public.things", %{
      columns: ["id", "value"],
      primary_key: ["id"],
      replica_identity: :full
    })

    assert {:ok, info} = TableInfo.fetch("public", "things")
    assert info.columns == ["id", "value"]
    assert info.primary_key == ["id"]
    assert info.replica_identity == :full
  end
end
