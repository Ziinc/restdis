defmodule RestdisRepo.ShapeDefinitionsReplicationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  restdis_pub publishes every table, so Postgres refuses UPDATE and DELETE on a
  table without a replica identity. Shape definitions must stay editable.
  """

  setup do
    :ok = RestdisRepo.Release.migrate()

    RestdisRepo.query!("""
    INSERT INTO shape_definitions (tenant_id, name, "table", inserted_at, updated_at)
    VALUES ('replication-test', 'orders', 'orders', now(), now())
    ON CONFLICT (tenant_id, name) DO NOTHING
    """)

    on_exit(fn ->
      RestdisRepo.query!("DELETE FROM shape_definitions WHERE tenant_id = 'replication-test'")
    end)

    :ok
  end

  test "a shape definition can be updated" do
    %{num_rows: 1} =
      RestdisRepo.query!("""
      UPDATE shape_definitions SET "where" = 'id > 0'
      WHERE tenant_id = 'replication-test' AND name = 'orders'
      """)
  end

  test "a shape definition can be deleted" do
    %{num_rows: 1} =
      RestdisRepo.query!(
        "DELETE FROM shape_definitions WHERE tenant_id = 'replication-test' AND name = 'orders'"
      )
  end
end
