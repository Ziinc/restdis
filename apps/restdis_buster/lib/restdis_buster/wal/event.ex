defmodule RestdisBuster.WAL.Event do
  @moduledoc """
  Struct describing a single decoded WAL change (schema, table, operation, primary key).
  """

  @type op :: :insert | :update | :delete | :truncate | :message

  @type t :: %__MODULE__{
          tenant_id: String.t() | nil,
          schema: String.t() | nil,
          table: String.t() | nil,
          op: op() | nil,
          pk: term(),
          new_row: map() | nil,
          old_row: map() | nil,
          lsn: non_neg_integer() | nil,
          received_at: integer() | nil
        }

  defstruct [:tenant_id, :schema, :table, :op, :pk, :new_row, :old_row, :lsn, :received_at]
end
