defmodule RestdisElectric.Definition do
  @moduledoc """
  A shape definition: the table, the optional column list, and the optional
  filter with its parameters.

  A definition is validated against the table's real schema before it becomes
  a shape. Validation failures are domain values (`{:error, {:unknown_table,
  table}}` and friends); this module never speaks HTTP.
  """

  alias RestdisElectric.TableInfo

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          schema: String.t(),
          table: String.t(),
          columns: [String.t()] | nil,
          where: String.t() | nil,
          params: %{String.t() => String.t()},
          replica: :default | :full,
          log_mode: :full | :changes_only
        }

  @type error ::
          {:missing_table, nil}
          | {:unknown_table, String.t()}
          | {:missing_primary_key, [String.t()]}
          | {:unknown_columns, [String.t()]}
          | {:unsupported_where, String.t()}
          | {:unsupported_log_mode, String.t()}
          | {:unsupported_replica, String.t()}
          | {:missing_replica_identity, String.t()}

  defstruct [
    :tenant_id,
    :schema,
    :table,
    :columns,
    :where,
    params: %{},
    replica: :default,
    log_mode: :full
  ]

  @default_schema "public"

  @doc """
  Builds and validates a definition for `tenant_id` from raw shape parameters.

  Accepts the string keys `"table"`, `"columns"`, `"where"`, `"replica"` and
  `"log"`. `where`, `replica=full` and `log=changes_only` are not implemented
  yet and are rejected rather than silently ignored, so a client never receives
  a log that differs from the shape it asked for.
  """
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, error()}
  def new(tenant_id, params) when is_binary(tenant_id) and is_map(params) do
    with {:ok, {schema, table}} <- parse_table(params["table"]),
         {:ok, columns} <- parse_columns(params["columns"]),
         {:ok, replica} <- parse_replica(params["replica"]),
         {:ok, log_mode} <- parse_log_mode(params["log"]),
         :ok <- reject_where(params["where"]) do
      validate(%__MODULE__{
        tenant_id: tenant_id,
        schema: schema,
        table: table,
        columns: columns,
        replica: replica,
        log_mode: log_mode
      })
    end
  end

  @doc """
  Validates a definition against the table's real schema.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, error()}
  def validate(%__MODULE__{} = definition) do
    case TableInfo.fetch(definition.schema, definition.table) do
      {:ok, info} -> with_replica_identity(definition, info)
      :error -> {:error, {:unknown_table, qualified(definition)}}
    end
  end

  @doc """
  Returns the `schema.table` name the shape reads.
  """
  @spec qualified(t()) :: String.t()
  def qualified(%__MODULE__{schema: schema, table: table}), do: "#{schema}.#{table}"

  @doc """
  Returns the canonical text form used to derive the shape handle.

  Every field that changes the log appears here, in a fixed order, with no
  reliance on map ordering, atom ordering or term hashing. Two definitions
  produce the same text if and only if they produce the same log.
  """
  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{} = definition) do
    [
      "tenant=" <> definition.tenant_id,
      "schema=" <> definition.schema,
      "table=" <> definition.table,
      "columns=" <> canonical_columns(definition.columns),
      "where=" <> (definition.where || ""),
      "params=" <> canonical_params(definition.params),
      "replica=" <> Atom.to_string(definition.replica),
      "log=" <> Atom.to_string(definition.log_mode)
    ]
    |> Enum.join("\n")
  end

  defp canonical_columns(nil), do: "*"
  defp canonical_columns(columns), do: Enum.join(columns, ",")

  defp canonical_params(params) do
    params
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp parse_table(nil), do: {:error, {:missing_table, nil}}
  defp parse_table(""), do: {:error, {:missing_table, nil}}

  defp parse_table(table) when is_binary(table) do
    case String.split(table, ".", parts: 2) do
      [name] -> {:ok, {@default_schema, name}}
      [schema, name] when name != "" -> {:ok, {schema, name}}
      _ -> {:error, {:missing_table, nil}}
    end
  end

  defp parse_table(_), do: {:error, {:missing_table, nil}}

  defp parse_columns(nil), do: {:ok, nil}
  defp parse_columns(""), do: {:ok, nil}

  defp parse_columns(columns) when is_binary(columns) do
    parsed =
      columns
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if parsed == [], do: {:ok, nil}, else: {:ok, parsed}
  end

  defp parse_columns(columns) when is_list(columns), do: {:ok, columns}

  defp parse_replica(nil), do: {:ok, :default}
  defp parse_replica("default"), do: {:ok, :default}
  defp parse_replica(other), do: {:error, {:unsupported_replica, to_string(other)}}

  defp parse_log_mode(nil), do: {:ok, :full}
  defp parse_log_mode("full"), do: {:ok, :full}
  defp parse_log_mode(other), do: {:error, {:unsupported_log_mode, to_string(other)}}

  defp reject_where(nil), do: :ok
  defp reject_where(""), do: :ok
  defp reject_where(where), do: {:error, {:unsupported_where, where}}

  defp with_replica_identity(%__MODULE__{} = definition, info) do
    if info.replica_identity == :full do
      validate_columns(definition, info)
    else
      {:error, {:missing_replica_identity, qualified(definition)}}
    end
  end

  defp validate_columns(%__MODULE__{columns: nil} = definition, _info), do: {:ok, definition}

  defp validate_columns(%__MODULE__{columns: columns} = definition, info) do
    unknown = columns -- info.columns
    missing_pk = info.primary_key -- columns

    cond do
      unknown != [] -> {:error, {:unknown_columns, unknown}}
      missing_pk != [] -> {:error, {:missing_primary_key, missing_pk}}
      true -> {:ok, definition}
    end
  end
end
