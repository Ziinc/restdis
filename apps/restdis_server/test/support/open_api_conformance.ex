defmodule RestdisServer.Test.OpenApiConformance do
  @moduledoc """
  Asserts that a real `Req.Response.t()` conforms to the operation documented
  in `RestdisServer.HTTP.ApiSpec`, using `OpenApiSpex.Cast` to validate
  headers and the JSON body against the actual OpenAPI schemas rather than
  hand-rolled checks.
  """

  import ExUnit.Assertions

  alias OpenApiSpex.Cast
  alias OpenApiSpex.Cast.Error, as: CastError
  alias RestdisServer.HTTP.ApiSpec

  @doc """
  Asserts that `resp` conforms to the response documented for `method` and
  `path` at `resp.status` in the spec.
  """
  @spec assert_conforms!(String.t(), String.t(), Req.Response.t()) :: :ok
  def assert_conforms!(method, path, resp) do
    spec = ApiSpec.spec()
    operation = fetch_operation!(spec, method, path)

    response =
      Map.get(operation.responses, resp.status) ||
        flunk(
          "#{method} #{path} returned undocumented status #{resp.status}; " <>
            "documented statuses: #{inspect(Map.keys(operation.responses))}"
        )

    assert_headers!(spec, response, resp)
    assert_body!(spec, response, resp)
    :ok
  end

  defp fetch_operation!(spec, method, path) do
    path_item =
      Map.get(spec.paths, path) ||
        flunk("#{path} is not documented in the OpenAPI spec")

    Map.get(path_item, String.to_existing_atom(String.downcase(method))) ||
      flunk("#{method} #{path} is not documented in the OpenAPI spec")
  end

  defp assert_headers!(spec, response, resp) do
    Enum.each(response.headers || %{}, fn {name, header} ->
      assert_header!(spec, name, header, resp)
    end)
  end

  defp assert_header!(spec, name, header, resp) do
    values = Req.Response.get_header(resp, name)

    if header.required do
      assert values != [], "expected response header #{inspect(name)} to be present"
    end

    Enum.each(values, &assert_header_value!(spec, name, header, &1))
  end

  defp assert_header_value!(spec, name, header, value) do
    case Cast.cast(header.schema, value, spec.components.schemas) do
      {:ok, _} -> :ok
      {:error, errors} -> flunk(cast_error_message("header #{name}", errors))
    end
  end

  defp assert_body!(spec, response, resp) do
    case response.content["application/json"] do
      nil ->
        :ok

      %{schema: schema} ->
        body = decode_body!(resp)

        case Cast.cast(schema, body, spec.components.schemas) do
          {:ok, _} -> :ok
          {:error, errors} -> flunk(cast_error_message("response body", errors))
        end
    end
  end

  defp decode_body!(%{body: body}) when is_map(body) or is_list(body), do: body
  defp decode_body!(%{body: body}) when is_binary(body), do: Jason.decode!(body)

  defp cast_error_message(context, errors) do
    details = Enum.map_join(errors, "\n", &CastError.message/1)
    "#{context} did not conform to the OpenAPI schema:\n#{details}"
  end
end
