defmodule SupaCacherBuster.WAL.RelationCache do
  @moduledoc false

  @type column :: %{name: String.t(), flags: non_neg_integer()}
  @type relation :: %{schema: String.t(), table: String.t(), columns: [column()]}
  @type t :: %{non_neg_integer() => relation()}

  @spec new() :: t()
  def new, do: %{}

  @spec update(t(), non_neg_integer(), String.t(), String.t(), [column()]) :: t()
  def update(cache, oid, schema, table, columns) do
    Map.put(cache, oid, %{schema: schema, table: table, columns: columns})
  end

  @spec lookup(t(), non_neg_integer()) :: {:ok, relation()} | :not_found
  def lookup(cache, oid) do
    case Map.fetch(cache, oid) do
      {:ok, rel} -> {:ok, rel}
      :error -> :not_found
    end
  end
end
