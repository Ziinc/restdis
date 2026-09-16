defmodule RestdisReplicator.Origin.StubTest do
  use ExUnit.Case, async: false

  alias RestdisReplicator.Origin.Stub
  alias RestdisReplicator.TestUtils

  test "page_calls/1 is zero before any page has been requested" do
    dataset = TestUtils.dataset()

    assert Stub.page_calls(dataset) == 0
  end

  test "fetch_row/2 returns :not_found when no row matches" do
    dataset = TestUtils.dataset()
    TestUtils.seed(dataset, [%{"id" => 1, "name" => "row-1"}])
    on_exit(fn -> Stub.clear(dataset) end)

    assert :not_found = Stub.fetch_row(dataset, "99")
  end
end
