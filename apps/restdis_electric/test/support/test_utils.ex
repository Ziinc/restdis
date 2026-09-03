defmodule RestdisElectric.TestUtils do
  @moduledoc """
  Shared test helpers for the `restdis_electric` bounded context.
  """

  @doc """
  Retries `block` in 100ms slices until it stops raising or exiting, up to
  a 1000ms budget. Useful right after killing a process: the registry
  entry for its replacement can lag behind the `:DOWN` message by a beat,
  so an immediate call can still race a stale or not-yet-restarted
  process. Succeeds as soon as `block` succeeds.
  """
  defmacro eventually(do: block) do
    total_timeout = 1000
    interval = 100

    quote do
      attempts = max(div(unquote(total_timeout), unquote(interval)), 1)

      Enum.reduce_while(1..attempts, nil, fn attempt, _acc ->
        try do
          {:halt, unquote(block)}
        rescue
          e ->
            if attempt == attempts do
              reraise(e, __STACKTRACE__)
            else
              Process.sleep(unquote(interval))
              {:cont, nil}
            end
        catch
          :exit, reason ->
            if attempt == attempts do
              exit(reason)
            else
              Process.sleep(unquote(interval))
              {:cont, nil}
            end
        end
      end)
    end
  end

  @spec tenant_id() :: String.t()
  def tenant_id, do: "tenant_#{System.unique_integer([:positive])}"

  @spec put_table(String.t(), map()) :: :ok
  def put_table(qualified_name, info) do
    tables = Application.get_env(:restdis_electric, :tables, %{})
    Application.put_env(:restdis_electric, :tables, Map.put(tables, qualified_name, info))
  end

  @spec put_stub_rows(String.t(), [map()]) :: :ok
  def put_stub_rows(table, rows) do
    stub_rows = Application.get_env(:restdis_electric, :stub_rows, %{})
    Application.put_env(:restdis_electric, :stub_rows, Map.put(stub_rows, table, rows))
  end
end
