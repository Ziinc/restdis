defmodule RestdisRepo.Tenants do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:tenant_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "tenants" do
    field(:default_ttl_s, :integer, default: 60)
    field(:persist_cap, :integer, default: 50_000)
    field(:pgrst_base_url, :string)
    field(:pgrst_api_key, :string)
    field(:replica_url, :string)
    field(:allow_shape_deletion, :boolean, default: false)
    field(:direct_pg_url, :string)
    field(:max_shapes, :integer)
    field(:max_log_bytes, :integer)
    field(:max_waiting_clients, :integer)

    timestamps()
  end

  @doc """
  Builds a changeset casting and validating tenant attributes.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [
      :tenant_id,
      :default_ttl_s,
      :persist_cap,
      :pgrst_base_url,
      :pgrst_api_key,
      :replica_url,
      :allow_shape_deletion,
      :direct_pg_url,
      :max_shapes,
      :max_log_bytes,
      :max_waiting_clients
    ])
    |> validate_required([:tenant_id, :pgrst_base_url, :pgrst_api_key])
    |> validate_format(:tenant_id, ~r/\A[A-Za-z0-9_-]{1,64}\z/)
    |> validate_number(:default_ttl_s, greater_than: 0)
    |> validate_number(:persist_cap, greater_than: 0)
    |> validate_number(:max_shapes, greater_than: 0)
    |> validate_number(:max_log_bytes, greater_than: 0)
    |> validate_number(:max_waiting_clients, greater_than: 0)
  end
end
