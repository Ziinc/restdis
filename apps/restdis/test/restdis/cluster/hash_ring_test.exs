defmodule Restdis.Cache.Cluster.HashRingTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Cluster.HashRing

  describe "owner/2" do
    test "an empty ring owns nothing" do
      assert HashRing.owner(HashRing.new([]), "tenant_a") == nil
    end

    test "a single node owns every tenant" do
      ring = HashRing.new([:a@host])

      for tenant <- ~w(tenant_a tenant_b tenant_c) do
        assert HashRing.owner(ring, tenant) == :a@host
      end
    end

    test "ownership is deterministic across ring construction order" do
      nodes = [:a@host, :b@host, :c@host]
      ring_one = HashRing.new(nodes)
      ring_two = HashRing.new(Enum.reverse(nodes))

      for tenant <- tenants(200) do
        assert HashRing.owner(ring_one, tenant) == HashRing.owner(ring_two, tenant)
      end
    end
  end

  describe "add_node/2 and remove_node/2" do
    test "add_node/2 makes the node eligible for ownership" do
      ring = HashRing.new([:a@host])
      assert HashRing.nodes(HashRing.add_node(ring, :b@host)) == [:a@host, :b@host]
    end

    test "add_node/2 is idempotent" do
      ring = [:a@host] |> HashRing.new() |> HashRing.add_node(:a@host)
      assert HashRing.nodes(ring) == [:a@host]
    end

    test "remove_node/2 reassigns the departed node's tenants" do
      ring = HashRing.new([:a@host, :b@host])
      smaller = HashRing.remove_node(ring, :b@host)

      assert HashRing.nodes(smaller) == [:a@host]

      for tenant <- tenants(50) do
        assert HashRing.owner(smaller, tenant) == :a@host
      end
    end
  end

  describe "distribution" do
    test "adding a node redistributes less than 5% beyond the theoretical minimum" do
      tenants = tenants(5_000)
      ring_three = HashRing.new([:a@host, :b@host, :c@host])
      ring_four = HashRing.add_node(ring_three, :d@host)

      moved =
        Enum.count(tenants, fn tenant ->
          HashRing.owner(ring_three, tenant) != HashRing.owner(ring_four, tenant)
        end)

      minimum = length(tenants) / 4
      assert moved / length(tenants) <= 0.25 + 0.05
      assert moved >= minimum * 0.5
    end

    test "virtual nodes keep per-node load within 25% of the mean" do
      nodes = [:a@host, :b@host, :c@host, :d@host]
      ring = HashRing.new(nodes)
      tenants = tenants(10_000)

      counts =
        tenants
        |> Enum.frequencies_by(&HashRing.owner(ring, &1))
        |> Map.values()

      mean = length(tenants) / length(nodes)
      assert length(counts) == length(nodes)
      assert Enum.all?(counts, &(abs(&1 - mean) / mean < 0.25))
    end
  end

  defp tenants(count) do
    Enum.map(1..count, &"tenant_#{&1}")
  end
end
