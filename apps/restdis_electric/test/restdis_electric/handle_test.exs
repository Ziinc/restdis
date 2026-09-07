defmodule RestdisElectric.HandleTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias RestdisElectric.Definition
  alias RestdisElectric.Handle
  alias RestdisElectric.TestUtils

  setup do
    TestUtils.put_table("public.widgets", %{
      columns: ["id", "name"],
      primary_key: ["id"],
      replica_identity: :full
    })

    :ok
  end

  test "the hash is stable for the same definition and differs across tenants" do
    {:ok, a} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, b} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, c} = Definition.new("t2", %{"table" => "widgets"})

    assert Handle.hash(a) == Handle.hash(b)
    assert Handle.hash(a) != Handle.hash(c)
  end

  test "new/1 formats {hash}-{epoch_ms}" do
    {:ok, definition} = Definition.new("t1", %{"table" => "widgets"})
    handle = Handle.new(definition)

    assert [hash, epoch] = String.split(handle, "-", parts: 2)
    assert hash == Handle.hash(definition)
    assert {_, ""} = Integer.parse(epoch)
  end

  test "matches?/2 checks only the hash part, not the timestamp" do
    {:ok, definition} = Definition.new("t1", %{"table" => "widgets"})
    handle = Handle.hash(definition) <> "-1"

    assert Handle.matches?(handle, definition)
  end

  test "matches?/2 rejects a handle from a different definition" do
    {:ok, a} = Definition.new("t1", %{"table" => "widgets"})
    {:ok, b} = Definition.new("t2", %{"table" => "widgets"})

    refute Handle.matches?(Handle.new(b), a)
  end

  test "hash_of/1 rejects a non-binary handle" do
    assert Handle.hash_of(nil) == :error
    assert Handle.hash_of(123) == :error
  end

  test "hash_of/1 rejects a handle missing either half" do
    assert Handle.hash_of("") == :error
    assert Handle.hash_of("no-dash-missing") |> elem(0) == :ok
    assert Handle.hash_of("-123") == :error
    assert Handle.hash_of("abc-") == :error
  end

  property "two definitions that produce the same canonical form always hash the same" do
    check all(tenant_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      {:ok, a} = Definition.new(tenant_id, %{"table" => "widgets"})
      {:ok, b} = Definition.new(tenant_id, %{"table" => "widgets"})
      assert Handle.hash(a) == Handle.hash(b)
    end
  end
end
