defmodule RestdisElectric.Snapshotter do
  @moduledoc """
  Reads a shape's initial snapshot from PostgREST, one page at a time.

  Consistency with the log is kept by LSN bracketing: the caller records
  `L0`, the WAL position at the moment the snapshot starts, before calling
  this module, buffers changes from `L0` onward, and replays that buffer
  after the snapshot finishes. See `RestdisElectric` for that orchestration.
  Any row that both the snapshot and the replay produce is a duplicate
  `insert`, which is safe because inserts are idempotent per row.

  The implementation is chosen by the `:snapshot_reader` application
  environment key so the context's own tests need no HTTP origin.
  """

  alias RestdisElectric.Definition

  @callback stream(tenant_config :: map(), Definition.t(), page_fun :: ([map()] -> :ok)) ::
              :ok | {:error, term()}

  @page_size 1_000

  @doc """
  The number of rows fetched per snapshot page.
  """
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc """
  Streams every row of `definition`'s table, page by page, calling
  `page_fun` with each page's rows in primary-key order.

  `tenant_config` is the same map `restdis_server` already resolves from an
  API key: it must provide `:pgrst_base_url` (or `:replica_url`) and
  `:pgrst_api_key`.
  """
  @spec stream(map(), Definition.t(), ([map()] -> :ok)) :: :ok | {:error, term()}
  def stream(tenant_config, %Definition{} = definition, page_fun) when is_function(page_fun, 1) do
    impl().stream(tenant_config, definition, page_fun)
  end

  @doc """
  Returns the configured implementation module.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(
      :restdis_electric,
      :snapshot_reader,
      RestdisElectric.Snapshotter.PostgREST
    )
  end
end
