defmodule Credo.Check.Consistency.ModuleFilePath do
  @moduledoc """
  Checks that a module's name matches the namespace implied by its file path
  under a `lib/` directory.

  For example, in an app with source root `lib/`:

    * `lib/my_mod.ex` must define `MyMod`
    * `lib/my_mod/nested.ex` must define `MyMod.Nested`

  This also applies inside umbrella apps, where the app directory itself is
  part of the path (and therefore part of the expected namespace):

    * `apps/my_app/lib/my_app.ex` must define `MyApp`
    * `apps/my_app/lib/my_app/nested.ex` must define `MyApp.Nested`

  Segment comparison ignores case and underscores, so acronym-style module
  names (e.g. `MyApp.HTTP.Server` for `my_app/http/server.ex`) are allowed.
  The "context" convention of `foo/foo.ex` defining `Foo` (dropping the
  duplicated trailing segment) is also allowed.

  Files that define no module (e.g. plain scripts) or that live outside a
  `lib/` directory are ignored.
  """

  use Credo.Check,
    base_priority: :high,
    category: :consistency,
    param_defaults: [],
    explanations: [
      check: """
      A file's path under `lib/` should mirror its module's namespace, so
      that the module can be located from its path (and vice versa) without
      surprises.
      """
    ]

  alias Credo.Code

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    case expected_segments(source_file.filename) do
      nil ->
        []

      expected ->
        source_file
        |> Code.ast()
        |> find_module_defs()
        |> Enum.flat_map(&check_module(&1, expected, issue_meta))
    end
  end

  defp find_module_defs(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, name_parts} | _]} = node, acc ->
          {node, [{Module.concat(name_parts), meta[:line]} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp check_module({actual_module, line_no}, expected_segments, issue_meta) do
    actual_name = inspect(actual_module)
    actual_segments = String.split(actual_name, ".")

    if matches?(actual_segments, expected_segments) do
      []
    else
      expected_name = expected_segments |> Enum.map(&camelize/1) |> Enum.join(".")

      [
        format_issue(
          issue_meta,
          message:
            "Module #{actual_name} does not match its file path. " <>
              "Expected a module named #{expected_name} (or nested under it).",
          line_no: line_no
        )
      ]
    end
  end

  # The actual module must be exactly the expected namespace, or nested
  # under it. It may also collapse a duplicated trailing segment, i.e. a
  # file at `foo/foo.ex` may define `Foo` instead of `Foo.Foo`.
  defp matches?(actual_segments, expected_segments) do
    collapsed_expected =
      case List.last(expected_segments, nil) do
        nil ->
          nil

        last ->
          without_last = Enum.slice(expected_segments, 0..-2//1)

          case List.last(without_last, nil) do
            ^last -> without_last
            _ -> nil
          end
      end

    prefix_match?(actual_segments, expected_segments) or
      (collapsed_expected != nil and prefix_match?(actual_segments, collapsed_expected))
  end

  defp prefix_match?(actual_segments, expected_segments) do
    normalized_actual = Enum.map(actual_segments, &normalize/1)
    normalized_expected = Enum.map(expected_segments, &normalize/1)

    length(normalized_actual) >= length(normalized_expected) and
      Enum.take(normalized_actual, length(normalized_expected)) == normalized_expected
  end

  defp camelize(segment) do
    segment
    |> String.split("_")
    |> Enum.map_join("", &String.capitalize/1)
  end

  defp normalize(segment) do
    segment
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.downcase()
  end

  defp expected_segments(filename) do
    filename
    |> Path.relative_to_cwd()
    |> Path.split()
    |> drop_up_to_lib()
    |> case do
      nil ->
        nil

      segments ->
        segments
        |> List.update_at(-1, &String.replace_trailing(&1, ".ex", ""))
        |> Enum.flat_map(&String.split(&1, "."))
    end
  end

  # Drops everything up to and including the last "lib" segment in the path,
  # so both `lib/foo/bar.ex` and `apps/app_name/lib/foo/bar.ex` resolve to
  # the segments that make up the expected module namespace.
  defp drop_up_to_lib(segments) do
    case Enum.split_while(segments, &(&1 != "lib")) do
      {_before, ["lib" | rest]} when rest != [] -> rest
      _ -> nil
    end
  end
end
