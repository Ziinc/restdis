defmodule RestdisBuster.WAL.RelationCache do
  @moduledoc false

  @type column :: %{name: String.t(), flags: non_neg_integer()}
  @type relation :: %{schema: String.t(), table: String.t(), columns: [column()]}
  @type t :: %{non_neg_integer() => relation()}

  @doc """
  Returns an empty relation cache.
  """
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Stores the relation described by a WAL Relation frame under its `oid`.
  """
  @spec update(t(), non_neg_integer(), relation()) :: t()
  def update(cache, oid, relation) do
    Map.put(cache, oid, relation)
  end

  @doc """
  Returns the relation registered for `oid`.
  """
  @spec lookup(t(), non_neg_integer()) :: {:ok, relation()} | :not_found
  def lookup(cache, oid) do
    case Map.fetch(cache, oid) do
      {:ok, rel} -> {:ok, rel}
      :error -> :not_found
    end
  end
end
