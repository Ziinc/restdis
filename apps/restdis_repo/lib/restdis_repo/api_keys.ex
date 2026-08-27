defmodule RestdisRepo.ApiKeys do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:api_key, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_keys" do
    field(:tenant_id, :string)
    field(:status, :string, default: "active")

    timestamps()
  end

  @doc """
  Builds a changeset casting and validating API key attributes.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:api_key, :tenant_id, :status])
    |> validate_required([:api_key, :tenant_id])
    |> validate_inclusion(:status, ["active", "revoked"])
  end
end
