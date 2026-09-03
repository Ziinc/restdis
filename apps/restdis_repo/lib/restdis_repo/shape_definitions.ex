defmodule RestdisRepo.ShapeDefinitions do
  @moduledoc """
  A named shape, configured server-side for a tenant running in gatekeeper
  mode (`ELECTRIC_PRD.md`'s "Authentication" section).

  Gatekeeper mode binds a shape name to its table, `where`, `columns`, and
  `replica`, so the client sends only the name and protocol parameters, never
  the definition itself. `RestdisServer.TenantStore.Repo` reads every row for
  a tenant and passes them into `tenant_config[:shapes]` as plain data,
  because `restdis_electric` depends on `restdis` only and must never query
  `restdis_repo` directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "shape_definitions" do
    field(:tenant_id, :string)
    field(:name, :string)
    field(:table, :string)
    field(:where, :string)
    field(:columns, {:array, :string})
    field(:replica, :string, default: "default")

    timestamps()
  end

  @doc """
  Builds a changeset casting and validating a named shape definition.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(shape_definition, attrs) do
    shape_definition
    |> cast(attrs, [:tenant_id, :name, :table, :where, :columns, :replica])
    |> validate_required([:tenant_id, :name, :table])
    |> validate_inclusion(:replica, ["default", "full"])
    |> unique_constraint([:tenant_id, :name])
  end
end
