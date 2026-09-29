defmodule Restdis.Cache.ReverseIndexMeta do
  @moduledoc """
  Derives the `{table, pk}` rows and list flag a cached value is reverse-indexed under.
  """

  alias Restdis.Cache.Key

  @type t :: %{rows: [{String.t(), term()}], list?: boolean()}

  @doc """
  Derives the reverse index metadata of `value` cached under `key`, taking
  pks from `opts[:primary_keys]` or else from the `opts[:pk_column]` (default
  `"id"`) of the value, or of each element when it is a list.
  """
  @spec derive(Key.t(), term(), keyword()) :: t()
  def derive(key, value, opts \\ []) do
    pk_column = opts[:pk_column] || "id"

    pks =
      case opts[:primary_keys] do
        nil -> extract_pks(value, pk_column)
        explicit -> explicit
      end

    %{rows: Enum.map(pks, &{key.ident, &1}), list?: is_list(value)}
  end

  defp extract_pks(value, pk_column) when is_map(value) do
    case Map.fetch(value, pk_column) do
      {:ok, pk} -> [pk]
      :error -> []
    end
  end

  defp extract_pks(values, pk_column) when is_list(values) do
    Enum.flat_map(values, fn
      item when is_map(item) ->
        case Map.fetch(item, pk_column) do
          {:ok, pk} -> [pk]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp extract_pks(_, _), do: []
end
