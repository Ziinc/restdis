defmodule SupaCacherRepo.Tenants do
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
      :replica_url
    ])
    |> validate_required([:tenant_id, :pgrst_base_url, :pgrst_api_key])
    |> validate_format(:tenant_id, ~r/\A[A-Za-z0-9_-]{1,64}\z/)
    |> validate_number(:default_ttl_s, greater_than: 0)
    |> validate_number(:persist_cap, greater_than: 0)
  end
end
