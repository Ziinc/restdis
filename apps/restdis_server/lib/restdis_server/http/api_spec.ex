defmodule RestdisServer.HTTP.ApiSpec do
  @moduledoc """
  The OpenAPI description of `GET` and `DELETE /v1/shape`, expressed as
  `open_api_spex` structs so it can be validated with a real OpenAPI
  implementation instead of hand-rolled assertions.

  This documents the contract Restdis actually serves — the Electric
  shape-log protocol (https://electric.ax/openapi.html#/paths/~1v1~1shape) —
  and calls out two deliberate deviations from the upstream spec:
  `DELETE /v1/shape` answers `202 Accepted` with a JSON body rather than the
  upstream `204 No Content`, and every error response carries a JSON body of
  the shape `{"error": string}`.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{
    Components,
    Header,
    Info,
    MediaType,
    OpenApi,
    Operation,
    Parameter,
    PathItem,
    Reference,
    Response,
    Schema,
    SecurityScheme
  }

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{title: "Restdis Electric HTTP API", version: "1.0.0"},
      security: [%{"bearerAuth" => []}],
      paths: %{
        "/v1/shape" => %PathItem{
          get: get_shape_operation(),
          delete: delete_shape_operation()
        }
      },
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer"}
        },
        schemas: %{
          "ErrorBody" => error_body_schema(),
          "MustRefetchBody" => must_refetch_body_schema(),
          "DeleteShapeOkBody" => delete_shape_ok_body_schema(),
          "ShapeMessage" => shape_message_schema()
        }
      }
    }
  end

  defp error_body_schema do
    %Schema{
      type: :object,
      required: [:error],
      properties: %{error: %Schema{type: :string}}
    }
  end

  defp must_refetch_body_schema do
    %Schema{
      type: :object,
      required: [:error, :handle],
      properties: %{
        error: %Schema{type: :string},
        handle: %Schema{type: :string}
      }
    }
  end

  defp delete_shape_ok_body_schema do
    %Schema{
      type: :object,
      required: [:ok],
      properties: %{ok: %Schema{type: :boolean, enum: [true]}}
    }
  end

  defp shape_message_schema do
    %Schema{
      type: :object,
      required: [:headers],
      properties: %{
        key: %Schema{type: :string},
        value: %Schema{type: :object},
        old_value: %Schema{type: :object},
        headers: %Schema{type: :object}
      }
    }
  end

  defp ref(name), do: %Reference{"$ref": "#/components/schemas/#{name}"}

  defp get_shape_operation do
    %Operation{
      summary:
        "Fetch a snapshot or a range of a shape's log, optionally long-polling for new messages.",
      parameters: [
        %Parameter{name: :table, in: :query, required: true, schema: %Schema{type: :string}},
        %Parameter{name: :offset, in: :query, required: false, schema: %Schema{type: :string}},
        %Parameter{name: :handle, in: :query, required: false, schema: %Schema{type: :string}},
        %Parameter{
          name: :live,
          in: :query,
          required: false,
          schema: %Schema{type: :string, enum: ["true", "false", "1", "0"]}
        },
        %Parameter{
          name: :live_sse,
          in: :query,
          required: false,
          schema: %Schema{type: :string, enum: ["true", "false", "1", "0"]}
        },
        %Parameter{name: :cursor, in: :query, required: false, schema: %Schema{type: :string}},
        %Parameter{
          name: :replica,
          in: :query,
          required: false,
          schema: %Schema{type: :string, enum: ["default", "full"]}
        },
        %Parameter{name: :columns, in: :query, required: false, schema: %Schema{type: :string}},
        %Parameter{name: :where, in: :query, required: false, schema: %Schema{type: :string}}
      ],
      responses: %{
        200 => %Response{
          description: "Shape log messages, possibly empty when up to date.",
          headers: %{
            "electric-handle" => %Header{required: true, schema: %Schema{type: :string}},
            "electric-offset" => %Header{required: true, schema: %Schema{type: :string}},
            "electric-up-to-date" => %Header{
              required: true,
              schema: %Schema{type: :string, enum: ["true", "false"]}
            },
            "electric-schema" => %Header{required: true, schema: %Schema{type: :string}},
            "cache-control" => %Header{required: true, schema: %Schema{type: :string}},
            "etag" => %Header{required: true, schema: %Schema{type: :string}}
          },
          content: %{
            "application/json" => %MediaType{
              schema: %Schema{type: :array, items: ref("ShapeMessage")}
            }
          }
        },
        400 => %Response{
          description: "Invalid or missing query parameters.",
          headers: %{"cache-control" => %Header{required: true, schema: %Schema{type: :string}}},
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        },
        401 => %Response{
          description: "Missing or invalid API key.",
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        },
        409 => %Response{
          description:
            "The shape handle is no longer valid; the client must refetch from scratch.",
          headers: %{
            "location" => %Header{required: true, schema: %Schema{type: :string}},
            "cache-control" => %Header{required: true, schema: %Schema{type: :string}}
          },
          content: %{"application/json" => %MediaType{schema: ref("MustRefetchBody")}}
        },
        429 => %Response{
          description: "A tenant limit (shapes, log bytes, or waiting clients) was reached.",
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        },
        502 => %Response{
          description: "The snapshot could not be taken.",
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        }
      }
    }
  end

  defp delete_shape_operation do
    %Operation{
      summary: "Delete a shape, forcing every client subscribed to its handle to resync.",
      description: """
      Only served when the tenant config has `allow_shape_deletion: true`;
      otherwise behaves as if the route did not exist. Deviates from the
      upstream Electric spec's documented `204 No Content` by returning
      `202 Accepted` with a JSON acknowledgement body.
      """,
      parameters: [
        %Parameter{
          name: :handle,
          in: :query,
          required: true,
          schema: %Schema{type: :string, minLength: 1}
        }
      ],
      responses: %{
        202 => %Response{
          description:
            "The shape was deleted. A subsequent GET with the same handle returns 409 must-refetch.",
          content: %{"application/json" => %MediaType{schema: ref("DeleteShapeOkBody")}}
        },
        400 => %Response{
          description: "The 'handle' query parameter was missing or empty.",
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        },
        401 => %Response{
          description: "Missing or invalid API key.",
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        },
        404 => %Response{
          description: "Shape deletion is disabled for this tenant.",
          content: %{"application/json" => %MediaType{schema: ref("ErrorBody")}}
        }
      }
    }
  end
end
