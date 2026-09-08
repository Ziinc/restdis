defmodule RestdisBuster.TestUtils do
  @moduledoc false

  alias Ecto.Adapters.SQL.Sandbox
  alias Restdis.Cache.ReadThrough
  alias RestdisBuster.TenantTableConfig
  alias RestdisBuster.WAL.Event

  @doc """
  Like `assert_receive/2`, but instead of blocking for a single long
  timeout, retries in `interval`-sized slices until `total_timeout` has
  elapsed. Succeeds as soon as a matching message arrives, so it doesn't
  eat the full timeout on the happy path, while still tolerating slow
  delivery under load without needing a big fixed timeout.
  """
  defmacro assert_receive_eventually(pattern, total_timeout \\ 1000, interval \\ 100) do
    quote do
      attempts = max(div(unquote(total_timeout), unquote(interval)), 1)

      Enum.reduce_while(1..attempts, nil, fn attempt, _acc ->
        try do
          ExUnit.Assertions.assert_receive(unquote(pattern), unquote(interval))
          {:halt, :ok}
        rescue
          e in ExUnit.AssertionError ->
            if attempt == attempts do
              reraise e, __STACKTRACE__
            else
              {:cont, nil}
            end
        end
      end)
    end
  end

  @doc false
  @spec seed_table_config(String.t(), String.t(), map()) :: :ok
  def seed_table_config(schema, table, config) do
    ReadThrough.put(
      TenantTableConfig.Cache.cache_name(),
      "tenant_table_config/#{schema}.#{table}",
      config
    )
  end

  @doc false
  @spec clear_table_config() :: :ok
  def clear_table_config do
    ReadThrough.flush(TenantTableConfig.Cache.cache_name())
  end

  @spec insert_event(String.t(), String.t(), map()) :: Event.t()
  def insert_event(table, schema \\ "public", row \\ %{}) do
    %Event{op: :insert, schema: schema, table: table, new_row: row}
  end

  @spec update_event(String.t(), String.t(), map(), map()) :: Event.t()
  def update_event(table, schema \\ "public", old_row \\ %{}, new_row \\ %{}) do
    %Event{op: :update, schema: schema, table: table, old_row: old_row, new_row: new_row}
  end

  @spec delete_event(String.t(), String.t(), map()) :: Event.t()
  def delete_event(table, schema \\ "public", old_row \\ %{}) do
    %Event{op: :delete, schema: schema, table: table, old_row: old_row}
  end

  @spec truncate_event(String.t(), String.t()) :: Event.t()
  def truncate_event(table, schema \\ "public") do
    %Event{op: :truncate, schema: schema, table: table}
  end

  @doc """
  Checks out a shared sandbox connection for RestdisRepo so async workers
  spawned during the test (e.g. via WorkerSupervisor.start_worker/2) can
  query it too. Uses a dedicated owner process (not the test process
  itself), since shared mode reverts to :manual as soon as its owner
  exits: tying it to the test process would break the test's own
  on_exit callback if that callback also needs the connection (e.g. to
  clean up rows it inserted), because the test process has already
  exited by the time on_exit callbacks run. Stopping the owner restores
  :manual mode automatically, so later tests/files in the same
  `mix test` run aren't left with a shared owner that has exited.
  """
  def checkout_shared_repo! do
    owner = Sandbox.start_owner!(RestdisRepo, shared: true)
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(owner) end)
  end
end
