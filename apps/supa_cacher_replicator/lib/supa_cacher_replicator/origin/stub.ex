defmodule SupaCacherReplicator.Origin.Stub do
  @moduledoc """
  Origin implementation serving seeded rows from memory, used in tests and local runs.
  """

  @behaviour SupaCacherReplicator.Origin

  alias SupaCacherReplicator.Dataset

  @impl SupaCacherReplicator.Origin
  def list_page(%Dataset{} = dataset, offset, limit) do
    bump_page_calls(dataset)
    {:ok, dataset |> rows() |> Enum.slice(offset, limit)}
  end

  @impl SupaCacherReplicator.Origin
  def fetch_row(%Dataset{} = dataset, pk) do
    case Enum.find(rows(dataset), fn row -> Dataset.pk_of(dataset, row) == to_string(pk) end) do
      nil -> :not_found
      row -> {:ok, row}
    end
  end

  @doc """
  Replaces the rows served for `dataset`.
  """
  @spec seed(Dataset.t(), [map()]) :: :ok
  def seed(%Dataset{} = dataset, rows) do
    :persistent_term.put({__MODULE__, Dataset.registry_key(dataset)}, rows)
    :ok
  end

  @doc """
  Removes the rows and page counter seeded for `dataset`.
  """
  @spec clear(Dataset.t()) :: :ok
  def clear(%Dataset{} = dataset) do
    :persistent_term.erase({__MODULE__, Dataset.registry_key(dataset)})
    :persistent_term.erase({__MODULE__, :page_calls, Dataset.registry_key(dataset)})
    :ok
  end

  @doc """
  Returns how many pages were requested for `dataset` since the last `seed/2`.
  """
  @spec page_calls(Dataset.t()) :: non_neg_integer()
  def page_calls(%Dataset{} = dataset) do
    case :persistent_term.get({__MODULE__, :page_calls, Dataset.registry_key(dataset)}, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  defp rows(dataset) do
    :persistent_term.get({__MODULE__, Dataset.registry_key(dataset)}, [])
  end

  defp bump_page_calls(dataset) do
    key = {__MODULE__, :page_calls, Dataset.registry_key(dataset)}

    ref =
      case :persistent_term.get(key, nil) do
        nil ->
          ref = :counters.new(1, [:atomics])
          :persistent_term.put(key, ref)
          ref

        ref ->
          ref
      end

    :counters.add(ref, 1, 1)
  end
end
