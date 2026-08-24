defmodule SupaCacherServer.TenantStore.InMemory do
  @moduledoc """
  In-memory tenant store used in tests and local runs.

  Entries live in the process dictionary for test isolation; call `seed/1` from
  test setup to populate them.
  """

  @behaviour SupaCacherServer.TenantStore

  @type config :: SupaCacherServer.TenantStore.tenant_config()

  @impl SupaCacherServer.TenantStore
  def fetch_by_api_key(api_key) do
    entries = :persistent_term.get({__MODULE__, :entries}, [])

    case Enum.find(entries, fn e -> e[:api_key] == api_key end) do
      nil -> {:error, :not_found}
      entry -> {:ok, strip_api_key(entry)}
    end
  end

  @impl SupaCacherServer.TenantStore
  def fetch_by_tenant(tenant_id) do
    entries = :persistent_term.get({__MODULE__, :entries}, [])

    case Enum.find(entries, fn e -> e.tenant_id == tenant_id end) do
      nil -> {:error, :not_found}
      entry -> {:ok, strip_api_key(entry)}
    end
  end

  @impl SupaCacherServer.TenantStore
  def list_all do
    :persistent_term.get({__MODULE__, :entries}, []) |> Enum.map(&strip_api_key/1)
  end

  @doc """
  Replaces the stored tenant entries; call from test setup.
  """
  @spec seed([map()]) :: :ok
  def seed(entries) do
    :persistent_term.put({__MODULE__, :entries}, entries)
    :ok
  end

  @doc """
  Removes every stored tenant entry.
  """
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase({__MODULE__, :entries})
    :ok
  end

  defp strip_api_key(entry), do: Map.delete(entry, :api_key)
end
