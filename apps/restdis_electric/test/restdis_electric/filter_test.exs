defmodule RestdisElectric.FilterTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias RestdisElectric.Definition
  alias RestdisElectric.Eval
  alias RestdisElectric.Filter
  alias RestdisElectric.TestUtils

  setup do
    TestUtils.put_table("public.things", %{
      columns: ["id", "org_id", "name", "tags"],
      primary_key: ["id"],
      replica_identity: :full
    })

    %{tenant_id: TestUtils.tenant_id()}
  end

  defp definition(tenant_id, where) do
    {:ok, definition} =
      Definition.new(tenant_id, %{"table" => "things", "where" => where})

    definition
  end

  defp add(tenant_id, handle, where) do
    Filter.add(tenant_id, definition(tenant_id, where), handle)
    handle
  end

  describe "index_keys/1" do
    defp keys(where) do
      {:ok, compiled} = Eval.compile(where, %{})
      Filter.index_keys(compiled)
    end

    test "indexes field = constant and constant = field alike" do
      assert {:indexed, [{:scalar, "org_id", "n:4"}]} = keys("org_id = 4")
      assert {:indexed, [{:scalar, "org_id", "n:4"}]} = keys("4 = org_id")
    end

    test "indexes every value of an IN list, because it is a disjunction" do
      assert {:indexed, keys} = keys("org_id IN (1, 2)")
      assert Enum.sort(keys) == [{:scalar, "org_id", "n:1"}, {:scalar, "org_id", "n:2"}]
    end

    test "indexes array containment and constant = ANY(array)" do
      assert {:indexed, [{:array, "tags", "s:red"}]} = keys("tags @> ARRAY['red']")
      assert {:indexed, [{:array, "tags", "s:red"}]} = keys("'red' = ANY(tags)")
    end

    test "an OR needs both branches indexed" do
      assert {:indexed, keys} = keys("org_id = 1 OR org_id = 2")
      assert length(keys) == 2
      assert :unindexed = keys("org_id = 1 OR name LIKE 'a%'")
    end

    test "an AND needs only one branch indexed" do
      assert {:indexed, [{:scalar, "org_id", "n:1"}]} = keys("org_id = 1 AND name LIKE 'a%'")
      assert {:indexed, [{:scalar, "org_id", "n:1"}]} = keys("name LIKE 'a%' AND org_id = 1")
    end

    test "a clause with no indexable part is unindexed" do
      assert :unindexed = keys("name LIKE 'a%'")
      assert :unindexed = keys("org_id > 4")
      assert :unindexed = keys("org_id = name")
    end

    test "a shape with no filter is unindexed" do
      assert :unindexed = Filter.index_keys(nil)
    end

    test "a placeholder is indexed by the value bound to it" do
      {:ok, compiled} = Eval.compile("org_id = $1", %{"1" => "4"})
      assert {:indexed, [{:scalar, "org_id", "n:4"}]} = Filter.index_keys(compiled)
    end
  end

  describe "normalise/1" do
    test "text and numbers that compare equal share one key" do
      assert Filter.normalise("4") == Filter.normalise(4)
      assert Filter.normalise("4.0") == Filter.normalise(4)
      assert Filter.normalise(4.0) == Filter.normalise(4)
      assert Filter.normalise("red") != Filter.normalise("blue")
    end

    test "values with no stable key form are not indexable" do
      assert Filter.normalise(nil) == :error
      assert Filter.normalise(:null) == :error
      assert Filter.normalise(["a"]) == :error
    end
  end

  describe "candidates/4" do
    test "the index answers with only the shapes the row points at", %{tenant_id: tenant_id} do
      add(tenant_id, "org1", "org_id = 1")
      add(tenant_id, "org2", "org_id = 2")

      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}]) == ["org1"]
      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 2}]) == ["org2"]
      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 3}]) == []
    end

    test "unindexed shapes are always candidates", %{tenant_id: tenant_id} do
      add(tenant_id, "org1", "org_id = 1")
      add(tenant_id, "scan", "name LIKE 'a%'")

      assert Enum.sort(Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 9}])) ==
               ["scan"]

      assert Enum.sort(Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}])) ==
               ["org1", "scan"]
    end

    test "both images of an update are consulted", %{tenant_id: tenant_id} do
      add(tenant_id, "org1", "org_id = 1")
      add(tenant_id, "org2", "org_id = 2")

      candidates =
        Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 2}, %{"org_id" => 1}])

      assert Enum.sort(candidates) == ["org1", "org2"]
    end

    test "an array column matches on any element", %{tenant_id: tenant_id} do
      add(tenant_id, "red", "tags @> ARRAY['red']")

      assert Filter.candidates(tenant_id, "public", "things", [%{"tags" => ["blue", "red"]}]) ==
               ["red"]

      assert Filter.candidates(tenant_id, "public", "things", [%{"tags" => ["blue"]}]) == []
    end

    test "re-adding a handle does not duplicate it", %{tenant_id: tenant_id} do
      add(tenant_id, "org1", "org_id = 1")
      add(tenant_id, "org1", "org_id = 1")

      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}]) == ["org1"]
    end

    test "removing a handle drops every one of its entries", %{tenant_id: tenant_id} do
      add(tenant_id, "org1", "org_id IN (1, 2)")
      add(tenant_id, "scan", "name LIKE 'a%'")
      Filter.remove(tenant_id, "org1")
      Filter.remove(tenant_id, "scan")

      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}]) == []
      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 2}]) == []
    end

    test "one tenant's shapes never answer for another", %{tenant_id: tenant_id} do
      other = TestUtils.tenant_id()
      add(tenant_id, "mine", "org_id = 1")
      add(other, "theirs", "org_id = 1")

      assert Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}]) == ["mine"]
    end

    test "emits how many shapes the index answered with", %{tenant_id: tenant_id} do
      add(tenant_id, "org1", "org_id = 1")
      add(tenant_id, "scan", "name LIKE 'a%'")

      :telemetry.attach(
        "filter-lookup-test",
        [:restdis_electric, :filter, :lookup],
        fn _event, measurements, metadata, pid ->
          send(pid, {:lookup, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach("filter-lookup-test") end)

      Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}])

      assert_receive {:lookup, %{indexed: 1, unindexed: 1, candidates: 2}, %{table: "things"}}
    end
  end

  describe "throughput against shape count" do
    # The point of the index: cost per change must not follow shape count, not an absolute rate.
    @tag :benchmark
    test "indexed shapes: cost per change stays flat from 10 to 1,000 shapes" do
      small = measure_lookup(10)
      large = measure_lookup(1_000)

      assert large < small * 5,
             "1,000 shapes cost #{large}us per change, 10 shapes cost #{small}us"
    end

    # Documented for contrast: without an indexable clause every shape is a candidate, so cost does follow shape count.
    @tag :benchmark
    test "non-indexed shapes: every shape is a candidate" do
      tenant_id = TestUtils.tenant_id()
      definition = definition(tenant_id, "name LIKE 'a%'")

      for i <- 1..200, do: Filter.add(tenant_id, definition, "scan#{i}")

      assert length(Filter.candidates(tenant_id, "public", "things", [%{"org_id" => 1}])) == 200
    end

    defp measure_lookup(count) do
      tenant_id = TestUtils.tenant_id()

      for i <- 1..count do
        Filter.add(tenant_id, definition(tenant_id, "org_id = #{i}"), "h#{i}")
      end

      row = %{"id" => 1, "org_id" => 1, "name" => "a", "tags" => []}
      # Warm up, then measure.
      Filter.candidates(tenant_id, "public", "things", [row])

      {micros, _} =
        :timer.tc(fn ->
          for _ <- 1..200, do: Filter.candidates(tenant_id, "public", "things", [row])
        end)

      micros / 200
    end
  end

  describe "soundness" do
    # The index must never cause a missed shape: it is necessary for a match, so what it drops could not have matched.
    property "the index never drops a shape whose filter matches the row" do
      check all(
              org_id <- integer(1..5),
              tags <- list_of(member_of(~w(red blue green)), max_length: 3),
              name <- member_of(~w(alpha beta gamma)),
              max_runs: 200
            ) do
        tenant_id = TestUtils.tenant_id()
        row = %{"id" => 1, "org_id" => org_id, "name" => name, "tags" => tags}

        clauses = [
          "org_id = 1",
          "org_id = 2",
          "org_id IN (1, 3)",
          "org_id = 4 OR org_id = 5",
          "org_id = 1 AND name LIKE 'a%'",
          "tags @> ARRAY['red']",
          "'blue' = ANY(tags)",
          "name LIKE 'b%'",
          "org_id > 3"
        ]

        shapes =
          for {where, i} <- Enum.with_index(clauses) do
            handle = "h#{i}"
            definition = definition(tenant_id, where)
            Filter.add(tenant_id, definition, handle)
            {handle, definition}
          end

        matching =
          for {handle, definition} <- shapes,
              Eval.matches?(definition.filter, row),
              do: handle

        candidates = Filter.candidates(tenant_id, "public", "things", [row])

        assert MapSet.subset?(MapSet.new(matching), MapSet.new(candidates)),
               "index dropped #{inspect(MapSet.difference(MapSet.new(matching), MapSet.new(candidates)))} for #{inspect(row)}"
      end
    end
  end
end
