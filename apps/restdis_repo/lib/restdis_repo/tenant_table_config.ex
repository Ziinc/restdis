defmodule RestdisRepo.TenantTableConfig do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "tenant_table_config" do
    field(:tenant_id, :string, primary_key: true)
    field(:schema, :string, primary_key: true, default: "public")
    field(:table_name, :string, primary_key: true)
    field(:mode, :string, default: "ttl")
    field(:pk_column, :string, default: "id")
    field(:filter, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Builds a changeset casting and validating table configuration params.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, params) do
    struct
    |> cast(params, [:tenant_id, :schema, :table_name, :mode, :pk_column, :filter])
    |> validate_required([:tenant_id, :schema, :table_name])
    |> validate_inclusion(:mode, ["ttl", "replication"])
  end
end
