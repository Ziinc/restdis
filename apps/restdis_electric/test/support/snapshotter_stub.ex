defmodule RestdisElectric.Snapshotter.Stub do
  @moduledoc """
  Test snapshot reader that pages through a fixed, in-memory row set instead
  of calling PostgREST, configured via `:restdis_electric, :stub_rows`.

  A table configured as `{:error, reason}` fails its snapshot with that
  reason, and one configured as `:raise` raises mid-snapshot.
  """

  @behaviour RestdisElectric.Snapshotter

  alias RestdisElectric.Definition
  alias RestdisElectric.Snapshotter

  @impl RestdisElectric.Snapshotter
  def stream(_tenant_config, %Definition{} = definition, page_fun) do
    case Application.get_env(:restdis_electric, :stub_rows, %{})[definition.table] || [] do
      {:error, _reason} = error ->
        error

      :raise ->
        raise "snapshot of #{definition.table} failed"

      rows ->
        rows
        |> Enum.chunk_every(Snapshotter.page_size())
        |> Enum.each(page_fun)

        :ok
    end
  end
end
