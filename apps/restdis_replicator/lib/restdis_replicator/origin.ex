defmodule RestdisReplicator.Origin do
  @moduledoc """
  Behaviour for reading replicated rows from PostgREST, plus dispatch helpers.
  """

  alias RestdisReplicator.Dataset

  @callback list_page(Dataset.t(), offset :: non_neg_integer(), limit :: pos_integer()) ::
              {:ok, [map()]} | {:error, term()}

  @callback fetch_row(Dataset.t(), pk :: String.t()) ::
              {:ok, map()} | :not_found | {:error, term()}

  @doc """
  Reads one page of `dataset` through the configured origin implementation.
  """
  @spec list_page(Dataset.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def list_page(dataset, offset, limit), do: impl().list_page(dataset, offset, limit)

  @doc """
  Reads a single row of `dataset` through the configured origin implementation.
  """
  @spec fetch_row(Dataset.t(), String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def fetch_row(dataset, pk), do: impl().fetch_row(dataset, pk)

  defp impl do
    Application.get_env(
      :restdis_replicator,
      :origin,
      RestdisReplicator.Origin.PostgREST
    )
  end
end
