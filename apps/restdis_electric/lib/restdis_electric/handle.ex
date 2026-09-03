defmodule RestdisElectric.Handle do
  @moduledoc """
  Computes and parses shape handles.

  Electric formats a handle as `{hash}-{epoch_ms}` and treats it as opaque
  text. We must keep that format, and the hash must be stable forever: it is
  written to disk and clients hold it across deployments and Erlang upgrades.
  `:erlang.phash2/1` is unsuitable for that (it is only stable within one
  running process), so we hash the definition's canonical text form with
  SHA-256 and truncate it.
  """

  alias RestdisElectric.Definition

  @type t :: String.t()

  @hash_bytes 16

  @doc """
  Computes the stable hash for `definition`, independent of when the shape was
  created. Two definitions that produce the same canonical form produce the
  same hash.
  """
  @spec hash(Definition.t()) :: String.t()
  def hash(%Definition{} = definition) do
    definition
    |> Definition.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, @hash_bytes)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Builds a new handle for `definition`, stamped with the current time.
  """
  @spec new(Definition.t()) :: t()
  def new(%Definition{} = definition) do
    "#{hash(definition)}-#{System.os_time(:millisecond)}"
  end

  @doc """
  Extracts the hash part of a handle, without validating that the handle
  exists.
  """
  @spec hash_of(t()) :: {:ok, String.t()} | :error
  def hash_of(handle) when is_binary(handle) do
    case String.split(handle, "-", parts: 2) do
      [hash, epoch] when hash != "" and epoch != "" -> {:ok, hash}
      _ -> :error
    end
  end

  def hash_of(_), do: :error

  @doc """
  Returns true when `handle` was computed for `definition`, regardless of when
  the handle was created.
  """
  @spec matches?(t(), Definition.t()) :: boolean()
  def matches?(handle, %Definition{} = definition) do
    hash_of(handle) == {:ok, hash(definition)}
  end
end
