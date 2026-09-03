defmodule RestdisElectric.Snapshotter.BracketingStub do
  @moduledoc """
  Test snapshot reader that pages through fixed, in-memory rows like
  `RestdisElectric.Snapshotter.Stub`, but also runs a caller-supplied
  zero-arity side effect once per page, after handing the page to `page_fun`
  and before returning.

  Configured through the same `:restdis_electric, :stub_rows` key as `Stub`,
  plus `:restdis_electric, :bracketing_during_page` for the side effect. Used
  to simulate a WAL commit landing between `L0` and the moment the real
  PostgREST snapshot reads that same page — the concrete duplication case
  LSN bracketing exists to survive.
  """

  @behaviour RestdisElectric.Snapshotter

  alias RestdisElectric.Definition
  alias RestdisElectric.Snapshotter

  @impl RestdisElectric.Snapshotter
  def stream(_tenant_config, %Definition{} = definition, page_fun) do
    rows = Application.get_env(:restdis_electric, :stub_rows, %{})[definition.table] || []
    during_page = Application.get_env(:restdis_electric, :bracketing_during_page, fn -> :ok end)

    rows
    |> Enum.chunk_every(Snapshotter.page_size())
    |> Enum.each(fn page ->
      page_fun.(page)
      during_page.()
    end)

    :ok
  end
end
