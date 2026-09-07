defmodule Restdis.Cache.Origin.PostgRESTTest do
  use ExUnit.Case, async: true

  alias Restdis.Cache.Key
  alias Restdis.Cache.Origin.PostgREST

  test "fetch/2 always returns :error" do
    key = Key.build(:table, "products", %{})
    assert PostgREST.fetch("tenant", key) == :error
  end
end
