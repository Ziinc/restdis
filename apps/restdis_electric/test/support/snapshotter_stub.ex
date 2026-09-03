defmodule RestdisElectric.Snapshotter.Stub do
  @moduledoc """
  Test snapshot reader that pages through a fixed, in-memory row set instead
  of calling PostgREST, configured via `:restdis_electric, :stub_rows`.
  """

  @behaviour RestdisElectric.Snapshotter

  alias RestdisElectric.Definition
  alias RestdisElectric.Snapshotter

  @impl RestdisElectric.Snapshotter
  def stream(_tenant_config, %Definition{} = definition, page_fun) do
    rows = Application.get_env(:restdis_electric, :stub_rows, %{})[definition.table] || []

    rows
    |> Enum.chunk_every(Snapshotter.page_size())
    |> Enum.each(page_fun)

    :ok
  end
end
