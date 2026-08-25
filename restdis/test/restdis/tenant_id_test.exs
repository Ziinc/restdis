defmodule Restdis.Cache.TenantIdTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.TenantId

  describe "valid?/1" do
    test "accepts alphanumeric" do
      assert TenantId.valid?("tenant123")
    end

    test "accepts hyphens and underscores" do
      assert TenantId.valid?("my-tenant_01")
    end

    test "accepts 64 chars" do
      assert TenantId.valid?(String.duplicate("a", 64))
    end

    test "rejects empty string" do
      refute TenantId.valid?("")
    end

    test "rejects 65 chars" do
      refute TenantId.valid?(String.duplicate("a", 65))
    end

    test "rejects path traversal" do
      refute TenantId.valid?("../etc/passwd")
    end

    test "rejects forward slash" do
      refute TenantId.valid?("tenant/sub")
    end

    test "rejects spaces" do
      refute TenantId.valid?("my tenant")
    end
  end

  describe "cast!/1" do
    test "returns valid id unchanged" do
      assert TenantId.cast!("valid-id") == "valid-id"
    end

    test "raises on invalid id" do
      assert_raise ArgumentError, fn -> TenantId.cast!("../bad") end
    end
  end
end
