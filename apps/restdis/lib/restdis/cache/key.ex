defmodule Restdis.Cache.Key do
  @moduledoc """
  Cache key construction, encoding and decoding of the wire representation.
  """

  @type scope :: :table | :rpc | :view | :shape | :raw

  @type t :: %__MODULE__{
          scope: scope(),
          ident: String.t(),
          params_hash: non_neg_integer()
        }

  defstruct [:scope, :ident, :params_hash]

  @scope_to_wire %{table: "t", rpc: "r", view: "v", shape: "s"}
  @wire_to_scope %{"t" => :table, "r" => :rpc, "v" => :view, "s" => :shape}

  @doc """
  Builds a cache key from a scope, identifier and query params.
  """
  @spec build(scope(), String.t(), map()) :: t()
  def build(scope, ident, params) when scope in [:table, :rpc, :view, :shape] do
    %__MODULE__{scope: scope, ident: ident, params_hash: :erlang.phash2(params)}
  end

  @doc """
  Encodes a key into its wire representation.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{scope: :raw, ident: ident}), do: ident

  def encode(%__MODULE__{scope: scope, ident: ident, params_hash: hash}) do
    "pgrst:#{@scope_to_wire[scope]}:#{URI.encode(ident)}:#{hash}"
  end

  @doc """
  Decodes a wire key back into a `t:t/0`.

  Keys prefixed `pgrst:` decode into the canonical `table`/`rpc`/`view`/`shape`
  scopes used by `PGRST.QUERY`/`PGRST.POLICY` and shape logs. Any other
  colon-free string decodes as
  a `:raw` key: a plain, user-managed key written via `SET` and readable via
  `GET`/`MGET`/`TTL`/`EXISTS`/`DEL`. Keys containing a colon but lacking the
  `pgrst:` prefix are reserved for the `<table>:<primary_key>` replicated
  dataset address space (see `RestdisReplicator.Dataset`) and fail to decode
  here so callers can fall back to that lookup.
  """
  @spec decode(String.t()) :: {:ok, t()} | :error
  def decode("pgrst:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [wire_scope, encoded_ident, hash_str] ->
        with {:ok, scope} <- Map.fetch(@wire_to_scope, wire_scope),
             {hash, ""} <- Integer.parse(hash_str) do
          {:ok, %__MODULE__{scope: scope, ident: URI.decode(encoded_ident), params_hash: hash}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def decode(raw) when is_binary(raw) do
    if raw == "" or String.contains?(raw, ":") do
      :error
    else
      {:ok, %__MODULE__{scope: :raw, ident: raw, params_hash: 0}}
    end
  end

  def decode(_), do: :error
end
