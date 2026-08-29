defmodule Restdis.Cache.Storage.FeoxDB.Native do
  @moduledoc """
  Rustler bindings for the `feoxdb_nif` crate under `native/feoxdb_nif`,
  wrapping the `feoxdb` Rust crate (https://github.com/mehrantsi/feoxdb).

  This crate has not been compiled in the environment it was authored in
  (no outbound access to crates.io to fetch `feoxdb`/`rustler`), so treat
  the NIF stubs below as unverified until built once with network access.
  """

  use Rustler, otp_app: :restdis, crate: "feoxdb_nif"

  @spec open(String.t() | nil) :: {:ok, reference()} | {:error, term()}
  def open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @spec put(reference(), binary(), binary()) :: :ok | {:error, term()}
  def put(_resource, _key, _value), do: :erlang.nif_error(:nif_not_loaded)

  @spec get(reference(), binary()) :: {:ok, binary() | nil} | {:error, term()}
  def get(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)

  @spec delete(reference(), binary()) :: boolean() | {:error, term()}
  def delete(_resource, _key), do: :erlang.nif_error(:nif_not_loaded)

  @spec clear(reference()) :: :ok | {:error, term()}
  def clear(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @spec select_all(reference()) :: [{binary(), binary()}] | {:error, term()}
  def select_all(_resource), do: :erlang.nif_error(:nif_not_loaded)

  @spec flush(reference()) :: :ok | {:error, term()}
  def flush(_resource), do: :erlang.nif_error(:nif_not_loaded)
end
