defmodule RestdisRepo.TenantsTest do
  use ExUnit.Case, async: true

  alias RestdisRepo.Tenants

  @valid_attrs %{
    tenant_id: "acme",
    pgrst_base_url: "https://pgrst.example.com",
    pgrst_api_key: "secret"
  }

  test "changeset is valid with required attrs" do
    changeset = Tenants.changeset(%Tenants{}, @valid_attrs)
    assert changeset.valid?
  end

  test "changeset requires tenant_id, pgrst_base_url and pgrst_api_key" do
    changeset = Tenants.changeset(%Tenants{}, %{})

    refute changeset.valid?
    assert %{tenant_id: ["can't be blank"]} = errors_on(changeset)
    assert %{pgrst_base_url: ["can't be blank"]} = errors_on(changeset)
    assert %{pgrst_api_key: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset rejects an invalid tenant_id format" do
    changeset = Tenants.changeset(%Tenants{}, Map.put(@valid_attrs, :tenant_id, "not valid!"))

    refute changeset.valid?
    assert %{tenant_id: [_ | _]} = errors_on(changeset)
  end

  test "changeset rejects non-positive numeric fields" do
    changeset =
      Tenants.changeset(
        %Tenants{},
        Map.merge(@valid_attrs, %{
          default_ttl_s: 0,
          persist_cap: -1,
          max_shapes: 0,
          max_log_bytes: -5,
          max_waiting_clients: 0,
          max_log_operations: -1
        })
      )

    refute changeset.valid?
    errors = errors_on(changeset)
    assert %{default_ttl_s: [_ | _]} = errors
    assert %{persist_cap: [_ | _]} = errors
    assert %{max_shapes: [_ | _]} = errors
    assert %{max_log_bytes: [_ | _]} = errors
    assert %{max_waiting_clients: [_ | _]} = errors
    assert %{max_log_operations: [_ | _]} = errors
  end

  test "changeset rejects an unknown auth_mode" do
    changeset = Tenants.changeset(%Tenants{}, Map.put(@valid_attrs, :auth_mode, "nope"))

    refute changeset.valid?
    assert %{auth_mode: [_ | _]} = errors_on(changeset)
  end

  test "changeset accepts a known auth_mode" do
    changeset = Tenants.changeset(%Tenants{}, Map.put(@valid_attrs, :auth_mode, "open"))

    assert changeset.valid?
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
