defmodule RestdisElectric.Message do
  @moduledoc """
  A single entry in a shape log: a change message or a control message.

  A change message carries the operation and the row (`key`/`value`, with an
  optional `old_value` once `replica=full` ships in Phase 3). A control message
  carries only a control marker, `"up-to-date"` or `"must-refetch"`, and no row.
  Both are addressed by an `t:RestdisElectric.Offset.t/0` position in the log.
  """

  alias RestdisElectric.Offset

  @type operation :: :insert | :update | :delete
  @type control :: :up_to_date | :must_refetch

  @type t :: %__MODULE__{
          offset: Offset.t(),
          key: String.t() | nil,
          value: map() | nil,
          old_value: map() | nil,
          operation: operation() | nil,
          control: control() | nil
        }

  @enforce_keys [:offset]
  defstruct [:offset, :key, :value, :old_value, :operation, :control]

  @doc """
  Builds a change message for `operation` on `row`, keyed by its primary key.
  """
  @spec change(Offset.t(), operation(), String.t(), map()) :: t()
  def change(offset, operation, key, value) when operation in [:insert, :update, :delete] do
    %__MODULE__{offset: offset, operation: operation, key: key, value: value}
  end

  @doc """
  Builds a control message.
  """
  @spec control(Offset.t(), control()) :: t()
  def control(offset, control) when control in [:up_to_date, :must_refetch] do
    %__MODULE__{offset: offset, control: control}
  end

  @doc """
  Returns true when `message` is a control message rather than a change.
  """
  @spec control?(t()) :: boolean()
  def control?(%__MODULE__{control: nil}), do: false
  def control?(%__MODULE__{}), do: true
end
