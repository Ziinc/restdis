# ReverseIndex.purge_table/3 benchmark, contrasted with purge_row/4.
#
# `purge_table/3` (`apps/restdis/lib/restdis/cache/reverse_index.ex`) runs an
# unindexed `:ets.match/2` over the whole `:bag` forward table, `Enum.uniq`s
# the result, then does one `:ets.match_delete/2` per matched cache key. It
# runs synchronously on the WAL/buster invalidation path
# (`Cache.flush_table/3`), so its cost directly gates replication lag on every
# row change. `purge_row/4` does an indexed `:ets.lookup/2` instead and is the
# fast baseline it should be compared against.
#
# Run with:
#
#     mix run --no-start apps/restdis/bench/reverse_index_purge_table_bench.exs
#
# This is a standalone Benchee script (not an ExUnit test) and is not part
# of `mix test`.

Code.require_file("support/cache_bench_helper.exs", __DIR__)

alias Restdis.Bench.CacheHelper, as: H
alias Restdis.Cache.Key
alias Restdis.Cache.ReverseIndex

H.setup_app(Path.join(System.tmp_dir!(), "restdis_bench_reverse_index_purge"))

name = H.name()
table_cardinalities = [100, 1_000, 10_000]
rows_per_table = 5

add_table = fn tenant_id, table ->
  Enum.each(1..rows_per_table, fn pk ->
    ReverseIndex.add(name, tenant_id, {table, pk}, Key.build(:table, table, %{"pk" => pk}))
  end)
end

Enum.each(table_cardinalities, fn table_count ->
  tenant_id = H.fresh_tenant("ridxpurge#{table_count}_")

  # `table_count` distinct tables, each with `rows_per_table` rows, each row
  # backing one cache key: total index size scales with `table_count`.
  Enum.each(1..table_count, fn t -> add_table.(tenant_id, "table_#{t}") end)

  Benchee.run(
    %{
      "purge_row (indexed lookup, index_size=#{table_count * rows_per_table})" => fn ->
        # Re-add immediately so repeated iterations keep finding a row to purge.
        key = Key.build(:table, "table_1", %{"pk" => 1})
        ReverseIndex.add(name, tenant_id, {"table_1", 1}, key)
        ReverseIndex.purge_row(name, tenant_id, "table_1", 1)
      end,
      "purge_table (full scan, table_count=#{table_count})" => fn ->
        table = "table_#{Enum.random(2..table_count)}"
        add_table.(tenant_id, table)
        ReverseIndex.purge_table(name, tenant_id, table)
      end
    },
    time: 2,
    warmup: 1,
    memory_time: 0.5,
    print: [configuration: false],
    title: "ReverseIndex purge_row vs purge_table, table_count=#{table_count}"
  )
end)
