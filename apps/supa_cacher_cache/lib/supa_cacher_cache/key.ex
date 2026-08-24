defmodule SupaCacherCache.Key do
  @moduledoc """
  Cache key construction, encoding and decoding of the wire representation.
  """

  @type scope :: :table | :rpc | :view

  @type t :: %__MODULE__{
          scope: scope(),
          ident: String.t(),
          params_hash: non_neg_integer()
        }

  defstruct [:scope, :ident, :params_hash]

  @scope_to_wire %{table: "t", rpc: "r", view: "v"}
  @wire_to_scope %{"t" => :table, "r" => :rpc, "v" => :view}

  @spec build(scope(), String.t(), map()) :: t()
  def build(scope, ident, params) when scope in [:table, :rpc, :view] do
    %__MODULE__{scope: scope, ident: ident, params_hash: :erlang.phash2(params)}
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{scope: scope, ident: ident, params_hash: hash}) do
    "pgrst:#{@scope_to_wire[scope]}:#{URI.encode(ident)}:#{hash}"
  end

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

  def decode(_), do: :error
end
