defmodule Credo.Check.Design.NamespaceTrespassing do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      namespaces: %{
        "supa_cacher_repo" => SupaCacherRepo,
        "supa_cacher_buster" => SupaCacherBuster,
        "supa_cacher_replicator" => SupaCacherReplicator,
        "supa_cacher_server" => SupaCacherServer
      },
      allowed: %{
        SupaCacherRepo => [],
        SupaCacherBuster => [SupaCacherRepo],
        SupaCacherReplicator => [SupaCacherRepo],
        SupaCacherServer => [SupaCacherRepo, SupaCacherReplicator]
      }
    ],
    explanations: [
      check: """
      Restricts which umbrella apps' modules a given app may reference, based on that app's
      declared `mix.exs` dependencies.

      Each umbrella app under `apps/` may only reference its own modules, modules from Elixir
      / its core (non-umbrella) deps, or modules belonging to another umbrella app it
      explicitly depends on via `{:other_app, in_umbrella: true}`.

      Referencing a module from an umbrella app that isn't a declared dependency
      ("namespace trespassing") hides a real coupling that `mix.exs` doesn't advertise, and
      can silently introduce dependency cycles or make apps impossible to extract, test, or
      deploy independently.
      """,
      params: [
        namespaces: "Map of umbrella app directory name (under `apps/`) to its root module.",
        allowed: "Map of an app's root module to the list of other apps' root modules it may reference."
      ]
    ]

  @impl true
  def run(%Credo.SourceFile{filename: filename} = source_file, params) do
    namespaces = Credo.Check.Params.get(params, :namespaces, __MODULE__)
    allowed = Credo.Check.Params.get(params, :allowed, __MODULE__)

    case owning_app(filename, namespaces) do
      nil ->
        []

      own_module ->
        other_roots = namespaces |> Map.values() |> MapSet.new() |> MapSet.delete(own_module)
        allowed_roots = allowed |> Map.get(own_module, []) |> MapSet.new()
        issue_meta = Credo.IssueMeta.for(source_file, params)

        Credo.Code.prewalk(
          source_file,
          &traverse(&1, &2, issue_meta, own_module, other_roots, allowed_roots),
          []
        )
    end
  end

  defp owning_app(filename, namespaces) do
    with [_, app_dir] <- Regex.run(~r{^apps/([^/]+)/}, filename),
         {:ok, own_module} <- Map.fetch(namespaces, app_dir) do
      own_module
    else
      _ -> nil
    end
  end

  defp traverse(
         {:__aliases__, meta, [first | _]} = ast,
         issues,
         issue_meta,
         own_module,
         other_roots,
         allowed_roots
       )
       when is_atom(first) do
    trespassed_module = Module.concat([first])

    if MapSet.member?(other_roots, trespassed_module) and
         not MapSet.member?(allowed_roots, trespassed_module) do
      {ast, [issue_for(issue_meta, meta[:line], own_module, trespassed_module) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta, _own_module, _other_roots, _allowed_roots) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line_no, own_module, trespassed_module) do
    format_issue(
      issue_meta,
      message:
        "Namespace trespassing: #{inspect(own_module)} references #{inspect(trespassed_module)}, " <>
          "which is not declared as an in_umbrella dependency in mix.exs.",
      line_no: line_no,
      trigger: inspect(trespassed_module)
    )
  end
end
