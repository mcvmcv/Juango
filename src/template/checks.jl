# Checking templates: `manage.jl check --tag templates` ---------------------------------------------------
#
# Template mistakes are found when a page renders, often by a user. The check parses every
# template in TEMPLATE_DIRS and the apps' `templates/` (Juango's own are known to be fine) and
# reports syntax errors, unknown tags and filters (with the closest known name), `{% url %}`
# names that don't exist, and `{% extends %}` / `{% include %}` of templates that don't exist.

const TEMPLATE_EXTENSIONS = (".html", ".htm", ".txt", ".xml", ".email", ".svg", ".md", ".js", ".css", ".json")

"Each node of a template, depth first."
function each_node(f, nodes)
    for n in nodes
        f(n)
        for nl in child_nodelists(n)
            each_node(f, nl)
        end
        n isa ExtendsNode && each_node(f, n.nodes)
    end
end

literal_name(e::FilterExpr) = (e.base isa Literal && isempty(e.filters) && e.base.value isa AbstractString) ? String(e.base.value) : nothing

"The closest name to `name` among `names` (2 edits at most), as \"; did you mean 'x'?\", or \"\"."
function did_you_mean(name, names)
    best, d = nothing, 3
    for n in names
        k = edit_distance(name, n)
        k < d && ((best, d) = (n, k))
    end
    best === nothing ? "" : "; did you mean '$best'?"
end

"""
    template_issues(; dirs = template dirs) -> Vector{Tuple{String,String,String}}

Problems in the project's templates, as (id, template, message): `templates.E101` syntax errors
(unknown tags and filters among them, with a suggestion), `templates.E102` `{% url %}` names that
don't exist, `templates.E103` `{% extends %}` / `{% include %}` targets that don't exist.
"""
function template_issues(; dirs = nothing)
    out = Tuple{String,String,String}[]
    roots = something(dirs, String[d for d in template_dirs() if normpath(d) != normpath(BUILTIN_TEMPLATE_DIR)])
    for root in roots
        isdir(root) || continue
        for (dir, _, files) in walkdir(root), f in files
            lowercase(splitext(f)[2]) in TEMPLATE_EXTENSIONS || continue
            path = joinpath(dir, f)
            name = replace(relpath(path, root), '\\' => '/')
            src = try read(path, String) catch; continue end
            t = try
                Template(src; name = name, origin = path)
            catch e
                e isa TemplateSyntaxError || continue
                msg = e.msg
                m = match(r"invalid block tag '([^']+)'", msg)
                m === nothing || (msg *= did_you_mean(m[1], keys(TAGS)))
                m = match(r"invalid filter: '([^']+)'", msg)
                m === nothing || (msg *= did_you_mean(m[1], keys(FILTERS)))
                push!(out, ("templates.E101", name, msg))
                continue
            end
            each_node(t.nodes) do n
                if n isa URLNode
                    u = literal_name(n.name)
                    u === nothing && return
                    try
                        reverse_url(u, (n.args isa Vector && !isempty(n.args) ? fill("1", length(n.args)) : String[])...;
                                    (Symbol(k) => "1" for (k, _) in n.kwargs)...)
                    catch e
                        e isa NoReverseMatch && occursin("is not a valid view name", e.msg) &&
                            push!(out, ("templates.E102", name, "{% url '$u' %}: no URL pattern is named '$u'"))
                    end
                elseif n isa ExtendsNode || n isa IncludeNode
                    target = literal_name(n isa ExtendsNode ? n.parent : n.template)
                    target === nothing && return
                    try
                        get_template(target)
                    catch e
                        e isa TemplateDoesNotExist || return
                        push!(out, ("templates.E103", name, "{% $(n isa ExtendsNode ? "extends" : "include") \"$target\" %}: no such template"))
                    end
                end
            end
        end
    end
    out
end
