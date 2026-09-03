defmodule RestdisElectric.TestSupport.MaterializedView do
  @moduledoc """
  A client's materialized view, reduced from a stream of shape log messages.

  `insert` sets a key to its value, `update` merges into a key (falling back
  to inserting it, since `REPLICA IDENTITY FULL` rows carry every column
  already), and `delete` removes the key. Every property test in this suite
  that models a client applying a log shares this single reducer, so a
  reducer bug cannot hide a real duplication bug.
  """

  @type key :: term()
  @type value :: term()
  @type state :: %{key() => value()}

  @doc """
  Applies one `{operation, key, value}` triple to `state`.

  `insert` and `update` both set the key to `value` unless `value` and the
  key's current value are both maps, in which case `update` merges them —
  matching a `REPLICA IDENTITY FULL` row, which already carries every
  column, while still tolerating scalar test values.
  """
  @spec apply(state(), :insert | :update | :delete, key(), value()) :: state()
  def apply(state, :insert, key, value), do: Map.put(state, key, value)

  def apply(state, :update, key, value),
    do: Map.put(state, key, merge(Map.get(state, key), value))

  def apply(state, :delete, key, _value), do: Map.delete(state, key)

  defp merge(%{} = current, %{} = value), do: Map.merge(current, value)
  defp merge(_current, value), do: value

  @doc """
  Applies a `RestdisElectric.Message.t/0`-shaped change message to `state`,
  keyed by the message's own `key`.
  """
  @spec apply_message(state(), map()) :: state()
  def apply_message(state, %{operation: operation, key: key, value: value}) do
    apply(state, operation, key, value)
  end
end
