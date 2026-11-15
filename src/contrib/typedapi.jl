# Typed APIs with OpenAPI (django-ninja's idea) ---------------------------------------------------------------
#
#     api = API(title = "Lab API", version = "1")
#     struct SampleIn; name::String; volume_ul::Float64; plate_id::Int; end
#     struct SampleOut; id::Int; name::String; well::String; end
#
#     get(api, "/samples/{id}"; response = SampleOut) do req, id::Int
#         s = get_object_or_404(Sample; id); SampleOut(s.id, s.name, s.well)
#     end
#     post(api, "/samples"; status = 201, response = SampleOut) do req, body::SampleIn
#         s = create(Sample; name = body.name, volume_ul = body.volume_ul, plate_id = body.plate_id)
#         SampleOut(s.id, s.name, s.well)
#     end
#     route!(api, "DELETE", "/samples/{id}"; status = 204) do req, id::Int ... end
#     urlpatterns = [path("api/", api_urls(api))]      # also api/openapi.json and api/docs
#
# A handler's arguments after `req` are its parameters, read from its types: a name in the path
# (`{id}`) is a path parameter; a struct (or a vector of structs) is the JSON body; anything else
# is a query parameter (`Union{T,Nothing}` or a default value makes it optional; `Vector{Int}`
# a repeated one). Bad input is a 422 listing every problem with where it is, as ninja and
# FastAPI answer. What the handler returns is encoded as JSON: structs, named tuples, dicts,
# vectors, models and querysets (through `ModelSchema`); an HttpResponse goes out as it is.

struct NoArgDefault end
const NO_ARG_DEFAULT = NoArgDefault()

struct APIParam
    name::Symbol
    type::Any
    where::Symbol            # :path, :query or :body
    default::Any             # NO_ARG_DEFAULT: required
end

struct APIRoute
    method::String
    path::String             # "/samples/{id}"
    handler::Any
    params::Vector{APIParam}
    status::Int
    response::Any            # a type, ModelSchema, Vector{...}, or nothing (for the docs)
    auth::Any                # nothing, false (public), or req -> anything but nothing/false
    summary::String
    tags::Vector{String}
end

"""
    API(; title = "API", version = "1", description = "", auth = nothing, csrf = false, docs = true)

A typed JSON API: add routes with `get(api, path) do req, ... end`, `post`, or `route!(api,
method, path)`, nest others with `add_router!`, and mount it with `path("api/", api_urls(api))`.
`auth(req)` (for every route unless a route says otherwise) returns the authenticated user, or
`nothing`/`false` for a 401: see `api_key_auth`, `bearer_auth` and `session_auth`. Routes are
CSRF-exempt unless `csrf = true` (needed when `session_auth` lets a browser's cookies in).
"""
mutable struct API
    title::String
    version::String
    description::String
    routes::Vector{APIRoute}
    auth::Any
    csrf::Bool
    docs::Bool
end
API(; title = "API", version = "1", description = "", auth = nothing, csrf::Bool = false, docs::Bool = true) =
    API(string(title), string(version), string(description), APIRoute[], auth, csrf, docs)
Base.show(io::IO, a::API) = print(io, "<API ", a.title, " (", length(a.routes), " routes)>")

"""
    route!(handler, api, method, path; status = 200, response = nothing, auth = <the API's>, summary = "", tags = [])

Add a route: see `API`. `response` (a struct type, `Vector{T}`, a `ModelSchema`) documents
the reply, and models or querysets returned are encoded through it when it's a `ModelSchema`.
"""
function route!(handler, api::API, method::AbstractString, path::AbstractString; status::Integer = 200, response = nothing,
                auth = :inherit, summary::AbstractString = "", tags = String[])
    startswith(path, "/") || (path = "/" * path)
    pnames = Set(Symbol(m[1]) for m in eachmatch(r"\{(\w+)\}", path))
    params = handler_params(handler, pnames)
    for n in pnames
        any(p -> p.name === n && p.where === :path, params) || throw(ArgumentError("route $method $path: the handler has no argument '$n'"))
    end
    count(p -> p.where === :body, params) <= 1 || throw(ArgumentError("route $method $path: at most one body argument"))
    push!(api.routes, APIRoute(uppercase(method), path, handler, params, status, response, auth,
                               string(summary), String[string(t) for t in tags]))
    handler
end
Base.get(handler::Function, api::API, path::AbstractString; kw...) = route!(handler, api, "GET", path; kw...)
post(handler::Function, api::API, path::AbstractString; kw...) = route!(handler, api, "POST", path; kw...)

"""
    add_router!(api, prefix, router::API; tags = [])

Mount another API's routes under `prefix` (`add_router!(api, "/plates", plates_api)`), keeping
their own auth unless they inherit the outer one.
"""
function add_router!(api::API, prefix::AbstractString, r::API; tags = String[])
    pre = "/" * strip(prefix, '/')
    for rt in r.routes
        push!(api.routes, APIRoute(rt.method, pre * rt.path, rt.handler, rt.params, rt.status, rt.response,
                                   rt.auth === :inherit ? (r.auth === nothing ? :inherit : r.auth) : rt.auth, rt.summary,
                                   isempty(rt.tags) ? String[string(t) for t in tags] : rt.tags))
    end
    api
end

# --- reading a handler's signature ---

const SCALAR_TYPES = Union{AbstractString,Number,Bool,Date,DateTime,Symbol,UUID,Decimal}
is_scalar_type(T) = T isa Type && (T <: SCALAR_TYPES || T <: Enum)
nonnothing(T) = T isa Union ? (T.a === Nothing ? T.b : T.b === Nothing ? T.a : T) : T
allows_nothing(T) = T isa Union && (T.a === Nothing || T.b === Nothing)
is_body_type(T) = (T = nonnothing(T); T isa DataType && !is_scalar_type(T) && (isstructtype(T) && !(T <: AbstractVector) && !(T <: AbstractDict) ||
                   T <: AbstractVector && !is_scalar_type(eltype(T)) || T <: AbstractDict))

function handler_params(handler, pathnames)
    ms = collect(methods(handler))
    isempty(ms) && throw(ArgumentError("the handler has no methods"))
    m = ms[argmax([m.nargs for m in ms])]               # the method with every argument
    nreq = minimum(m.nargs for m in ms)                 # arguments after this one have defaults
    names = Base.method_argnames(m)[2:end]              # (the first is the function itself)
    types = m.sig.parameters[2:end]
    out = APIParam[]
    for (i, (n, T)) in enumerate(zip(names, types))
        i == 1 && continue                              # req
        T === Any && (T = String)
        where = n in pathnames ? :path : is_body_type(T) ? :body : :query
        default = i + 1 > nreq ? :has_default : NO_ARG_DEFAULT
        allows_nothing(T) && default === NO_ARG_DEFAULT && (default = nothing)
        push!(out, APIParam(n, T, where, default))
    end
    out
end

# --- decoding input, collecting every problem ---

struct APIError
    loc::Vector{Any}
    msg::String
end

function decode_value(::Type{T}, x, loc, errs) where {T}
    if T === Any
        return x
    elseif T isa Union
        x === nothing && allows_nothing(T) && return nothing
        return decode_value(nonnothing(T), x, loc, errs)
    elseif x === nothing
        push!(errs, APIError(loc, "required")); return nothing
    elseif T <: Bool
        x isa Bool && return x
        x isa AbstractString && lowercase(x) in ("true", "1", "yes", "on") && return true
        x isa AbstractString && lowercase(x) in ("false", "0", "no", "off") && return false
    elseif T <: Integer
        x isa Integer && !(x isa Bool) && return T(x)
        x isa AbstractFloat && isinteger(x) && return T(x)
        x isa AbstractString && (v = tryparse(T, strip(x))) !== nothing && return v
        push!(errs, APIError(loc, "expected an integer")); return nothing
    elseif T <: AbstractFloat
        x isa Real && !(x isa Bool) && isfinite(x) && return T(x)
        x isa AbstractString && (v = tryparse(T, strip(x))) !== nothing && isfinite(v) && return v
        push!(errs, APIError(loc, "expected a number")); return nothing
    elseif T === Decimal
        x isa Real && !(x isa Bool) && return Decimal(string(x))
        x isa AbstractString && (v = tryparse(Decimal, strip(x))) !== nothing && return v
        push!(errs, APIError(loc, "expected a decimal number")); return nothing
    elseif T <: AbstractString
        x isa AbstractString && return T(x)
        push!(errs, APIError(loc, "expected a string")); return nothing
    elseif T === Symbol
        x isa AbstractString && return Symbol(x)
    elseif T === Date
        x isa AbstractString && (v = tryparse(Date, x)) !== nothing && return v
        push!(errs, APIError(loc, "expected a date (YYYY-MM-DD)")); return nothing
    elseif T === DateTime
        x isa AbstractString && (v = tryparse(DateTime, replace(x, r"Z$" => ""))) !== nothing && return v
        push!(errs, APIError(loc, "expected a date and time (ISO 8601)")); return nothing
    elseif T === UUID
        x isa AbstractString && (v = tryparse(UUID, x)) !== nothing && return v
        push!(errs, APIError(loc, "expected a UUID")); return nothing
    elseif T <: Enum
        names = [string(i) for i in instances(T)]
        x isa AbstractString && x in names && return instances(T)[findfirst(==(x), names)]
        push!(errs, APIError(loc, "expected one of " * join(names, ", "))); return nothing
    elseif T <: AbstractVector
        x isa AbstractVector || (push!(errs, APIError(loc, "expected a list")); return nothing)
        return eltype(T)[decode_value(eltype(T), v, vcat(loc, [i - 1]), errs) for (i, v) in enumerate(x)]
    elseif T <: AbstractDict
        x isa AbstractDict || (push!(errs, APIError(loc, "expected an object")); return nothing)
        return Dict{String,valtype(T)}(string(k) => decode_value(valtype(T), v, vcat(loc, [string(k)]), errs) for (k, v) in x)
    elseif isstructtype(T)
        x isa AbstractDict || (push!(errs, APIError(loc, "expected an object")); return nothing)
        n0 = length(errs)
        vals = Any[]
        for (f, FT) in zip(fieldnames(T), fieldtypes(T))
            v = get(x, string(f), nothing)
            if v === nothing && !haskey(x, string(f)) && !allows_nothing(FT)
                push!(errs, APIError(vcat(loc, [string(f)]), "field required")); push!(vals, nothing)
            else
                push!(vals, decode_value(FT, v, vcat(loc, [string(f)]), errs))
            end
        end
        known = Set(string.(fieldnames(T)))
        for k in keys(x)
            string(k) in known || push!(errs, APIError(vcat(loc, [string(k)]), "unknown field"))
        end
        length(errs) > n0 && return nothing
        return try
            T(vals...)
        catch e
            push!(errs, APIError(loc, e isa ArgumentError ? e.msg : "invalid value")); nothing
        end
    end
    push!(errs, APIError(loc, "invalid value")); nothing
end

# --- encoding output ---

"""
    ModelSchema(Model; fields = nothing, exclude = [])

How a model is shown by an API (and documented): its fields (the id and all concrete ones by
default, foreign keys as ids), as `response = ModelSchema(Sample; fields = [:id, :name])`
(`many = true` for a list); models and querysets the handler returns are encoded with it.
"""
struct ModelSchema
    model::Any
    fields::Vector{Symbol}
    many::Bool               # a list of them (a queryset), for the docs
end
function ModelSchema(T::Type; fields = nothing, exclude = Symbol[], many::Bool = false)
    names = fields === nothing ? vcat([:id], Symbol[f.name for f in concrete_fields(T) if f.kind !== :m2m && f.name !== :id]) : Symbol.(collect(fields))
    ModelSchema(T, filter(!in(Symbol.(exclude)), names), many)
end

function encode_model(@nospecialize(o::Model), schema)
    T = typeof(o)
    names = schema isa ModelSchema ? schema.fields : Symbol[f.name for f in concrete_fields(T) if f.kind !== :m2m]
    d = Dict{String,Any}()
    for n in names
        f = findfield(modelmeta(T), n)
        d[string(n)] = n in (:id, :pk) ? o.pk : f === nothing ? to_api_json(getproperty(o, n), nothing) :
                       value_to_json(f, field_data(o, attname(f)))
    end
    d
end
to_api_json(x::Union{Nothing,Missing,AbstractString,Number,AbstractChar}, schema = nothing) = x
to_api_json(x::Union{Date,DateTime,UUID,Decimal,Symbol}, schema = nothing) = string(x)
to_api_json(x::Enum, schema = nothing) = string(x)
to_api_json(x::AbstractFloat, schema = nothing) = isfinite(x) ? x : nothing
to_api_json(x::AbstractDict, schema = nothing) = Dict{String,Any}(string(k) => to_api_json(v, schema isa ModelSchema ? schema : nothing) for (k, v) in x)
to_api_json(x::NamedTuple, schema = nothing) = Dict{String,Any}(string(k) => to_api_json(v) for (k, v) in pairs(x))
to_api_json(x::Union{AbstractVector,Tuple}, schema = nothing) = Any[to_api_json(v, schema isa Type && schema <: AbstractVector ? eltype(schema) : schema) for v in x]
to_api_json(@nospecialize(x::Model), schema = nothing) = encode_model(x, schema)
to_api_json(@nospecialize(x::QuerySet), schema = nothing) = Any[to_api_json(o, schema) for o in fetch(x)]
function to_api_json(x::T, schema = nothing) where {T}
    isstructtype(T) || return x
    Dict{String,Any}(string(f) => to_api_json(getfield(x, f)) for f in fieldnames(T))
end

"""
    paginate_api(items, req; limit = 100, max_limit = 1000) -> Dict

`?limit=&offset=` paging for a list route: `Dict("count" => n, "items" => [...])`.
"""
function paginate_api(items, req; limit::Integer = 100, max_limit::Integer = 1000)
    lim = clamp(query_param(req, :limit, Int; default = limit), 0, max_limit)
    off = max(0, query_param(req, :offset, Int; default = 0))
    n = items isa QuerySet ? count(items) : length(items)
    page = items isa QuerySet ? (lim == 0 ? Any[] : fetch(items[off+1:off+lim])) : items[min(off + 1, end + 1):min(off + lim, end)]
    Dict{String,Any}("count" => n, "items" => page)
end

# --- authentication helpers ---

"`auth = api_key_auth(key -> user_or_nothing; header = \"X-API-Key\")`: an API key from a header."
api_key_auth(check; header::AbstractString = "X-API-Key") = req -> (k = Juango.header(req, lowercase(header), nothing); k === nothing ? nothing : check(k))
"`auth = bearer_auth(token -> user_or_nothing)`: `Authorization: Bearer <token>`."
bearer_auth(check) = req -> begin
    h = Juango.header(req, "authorization", "")
    m = match(r"^Bearer\s+(.+)$"i, h)
    m === nothing ? nothing : check(String(m[1]))
end
"`auth = session_auth`: the logged-in user of the session (use `API(...; csrf = true)` with it)."
session_auth(req) = is_authenticated(req.user) ? req.user : nothing

# --- serving ---

api_error_response(errs::Vector{APIError}) =
    JsonResponse(Dict("detail" => [Dict("loc" => e.loc, "msg" => e.msg) for e in errs]); status = 422)

function run_route(api::API, rt::APIRoute, req::Request, pathvals)
    auth = rt.auth === :inherit ? api.auth : rt.auth
    if auth !== nothing && auth !== false
        who = auth(req)
        (who === nothing || who === false) && return JsonResponse(Dict("detail" => "Not authenticated"); status = 401)
        req.meta[:api_auth] = who
    end
    errs = APIError[]
    args = Any[]
    body = nothing
    if any(p -> p.where === :body, rt.params)
        body = try
            isempty(req.body) ? nothing : JSON.parse(String(copy(req.body)))
        catch
            return api_error_response([APIError(Any["body"], "invalid JSON")])
        end
    end
    for p in rt.params
        if p.where === :path
            push!(args, decode_value(p.type, pathvals[p.name], Any["path", string(p.name)], errs))
        elseif p.where === :body
            if body === nothing
                p.default === :has_default && break                  # it and the rest take their defaults
                p.default === NO_ARG_DEFAULT && push!(errs, APIError(Any["body"], "required"))
                push!(args, p.default === NO_ARG_DEFAULT ? nothing : p.default)
            else
                push!(args, decode_value(p.type, body, Any["body"], errs))
            end
        else
            T = nonnothing(p.type)
            raw = T isa Type && T <: AbstractVector ? getlist(req.GET, string(p.name)) : get(req.GET, string(p.name), nothing)
            missing_ = raw === nothing || (raw isa AbstractVector && isempty(raw))
            if missing_ && p.default !== NO_ARG_DEFAULT
                p.default === :has_default && break                  # it and the rest take their defaults
                push!(args, p.default)
            else
                push!(args, decode_value(p.type, missing_ ? nothing : raw, Any["query", string(p.name)], errs))
            end
        end
    end
    isempty(errs) || return api_error_response(errs)
    out = rt.handler(req, args...)
    out isa HttpResponse && return out
    rt.status == 204 && return HttpResponse(""; status = 204)
    JsonResponse(to_api_json(out, rt.response); status = rt.status)
end

"""
    api_urls(api) -> Include

The API's URL patterns, for `path("api/", api_urls(api))`: its routes (405 for a method a path
doesn't have), `openapi.json` (the OpenAPI 3.1 document) and `docs` (Swagger UI).
"""
function api_urls(api::API)
    bypath = Dict{String,Vector{APIRoute}}()
    order = String[]
    for rt in api.routes
        haskey(bypath, rt.path) || push!(order, rt.path)
        push!(get!(bypath, rt.path, APIRoute[]), rt)
    end
    pats = Any[]
    for p in order
        routes = bypath[p]
        juango_route = replace(lstrip(p, '/'), r"\{(\w+)\}" => s"<str:\1>")
        view = function (req; kw...)
            rt = findfirst(r -> r.method == req.method || (req.method == "HEAD" && r.method == "GET"), routes)
            rt === nothing && return JsonResponse(Dict("detail" => "Method not allowed"); status = 405)
            run_route(api, routes[rt], req, Dict{Symbol,Any}(k => v for (k, v) in kw))
        end
        api.csrf || csrf_exempt(view)
        push!(pats, path(juango_route, view))
    end
    if api.docs
        push!(pats, path("openapi.json", req -> JsonResponse(openapi_schema(api; base = req.path[1:end-length("openapi.json")]))))
        push!(pats, path("docs", req -> HttpResponse(swagger_page(api, req.path[1:end-length("docs")] * "openapi.json"))))
    end
    include_urls(pats)
end

# --- the OpenAPI document ---

function json_schema(T, comps::Dict{String,Any})
    T === Any && return Dict{String,Any}()
    if T isa Union && allows_nothing(T)
        s = json_schema(nonnothing(T), comps)
        return Dict{String,Any}("anyOf" => Any[s, Dict("type" => "null")])
    end
    T isa ModelSchema && return T.many ? Dict{String,Any}("type" => "array", "items" => model_schema_json(T, comps)) : model_schema_json(T, comps)
    T isa Type || return Dict{String,Any}()
    T <: Bool && return Dict{String,Any}("type" => "boolean")
    T <: Integer && return Dict{String,Any}("type" => "integer")
    T <: AbstractFloat && return Dict{String,Any}("type" => "number")
    T === Decimal && return Dict{String,Any}("type" => "string", "format" => "decimal")
    T <: AbstractString || T === Symbol ? (return Dict{String,Any}("type" => "string")) : nothing
    T === Date && return Dict{String,Any}("type" => "string", "format" => "date")
    T === DateTime && return Dict{String,Any}("type" => "string", "format" => "date-time")
    T === UUID && return Dict{String,Any}("type" => "string", "format" => "uuid")
    T <: Enum && return Dict{String,Any}("type" => "string", "enum" => [string(i) for i in instances(T)])
    T <: AbstractVector && return Dict{String,Any}("type" => "array", "items" => json_schema(eltype(T), comps))
    T <: AbstractDict && return Dict{String,Any}("type" => "object", "additionalProperties" => json_schema(valtype(T), comps))
    if isstructtype(T)
        name = string(nameof(T))
        if !haskey(comps, name)
            comps[name] = Dict{String,Any}()           # (recursive types)
            props = Dict{String,Any}(string(f) => json_schema(FT, comps) for (f, FT) in zip(fieldnames(T), fieldtypes(T)))
            req = [string(f) for (f, FT) in zip(fieldnames(T), fieldtypes(T)) if !allows_nothing(FT)]
            comps[name] = Dict{String,Any}("type" => "object", "properties" => props, "required" => req)
        end
        return Dict{String,Any}("\$ref" => "#/components/schemas/" * name)
    end
    Dict{String,Any}()
end
function field_json_schema(f::Field)
    k = f.kind
    k in INT_KINDS || k === :fk ? Dict{String,Any}("type" => "integer") :
    k === :float ? Dict{String,Any}("type" => "number") :
    k === :bool ? Dict{String,Any}("type" => "boolean") :
    k === :decimal ? Dict{String,Any}("type" => "string", "format" => "decimal") :
    k === :date ? Dict{String,Any}("type" => "string", "format" => "date") :
    k === :datetime ? Dict{String,Any}("type" => "string", "format" => "date-time") :
    k === :uuid ? Dict{String,Any}("type" => "string", "format" => "uuid") :
    k in (:json, :hstore) ? Dict{String,Any}() :
    Dict{String,Any}("type" => "string")
end
function model_schema_json(s::ModelSchema, comps)
    T = s.model
    name = string(nameof(T)) * "Schema"
    if !haskey(comps, name)
        props = Dict{String,Any}()
        for n in s.fields
            f = findfield(modelmeta(T), n)
            props[string(n)] = n in (:id, :pk) || f === nothing ? Dict{String,Any}("type" => "integer") :
                               (f.null ? Dict{String,Any}("anyOf" => Any[field_json_schema(f), Dict("type" => "null")]) : field_json_schema(f))
        end
        comps[name] = Dict{String,Any}("type" => "object", "properties" => props, "required" => string.(s.fields))
    end
    Dict{String,Any}("\$ref" => "#/components/schemas/" * name)
end

"""
    openapi_schema(api; base = "/") -> Dict

The OpenAPI 3.1 document for the API (served at `openapi.json`): every route with its
parameters, body and reply schemas, and the 422 error format.
"""
function openapi_schema(api::API; base::AbstractString = "/")
    comps = Dict{String,Any}()
    paths = Dict{String,Any}()
    for rt in api.routes
        op = Dict{String,Any}("operationId" => lowercase(rt.method) * replace(rt.path, r"[^A-Za-z0-9]+" => "_"),
                              "responses" => Dict{String,Any}())
        isempty(rt.summary) || (op["summary"] = rt.summary)
        isempty(rt.tags) || (op["tags"] = rt.tags)
        ps = Any[]
        for p in rt.params
            p.where === :body && continue
            push!(ps, Dict{String,Any}("name" => string(p.name), "in" => string(p.where),
                                       "required" => p.where === :path || p.default === NO_ARG_DEFAULT,
                                       "schema" => json_schema(nonnothing(p.type), comps)))
        end
        isempty(ps) || (op["parameters"] = ps)
        b = findfirst(p -> p.where === :body, rt.params)
        if b !== nothing
            op["requestBody"] = Dict{String,Any}("required" => rt.params[b].default === NO_ARG_DEFAULT,
                                                 "content" => Dict("application/json" => Dict("schema" => json_schema(rt.params[b].type, comps))))
        end
        resp = Dict{String,Any}("description" => "OK")
        rt.response === nothing || rt.status == 204 ||
            (resp["content"] = Dict("application/json" => Dict("schema" => json_schema(rt.response, comps))))
        op["responses"][string(rt.status)] = resp
        isempty(rt.params) ||
            (op["responses"]["422"] = Dict{String,Any}("description" => "Validation error",
                                                       "content" => Dict("application/json" => Dict("schema" => Dict("\$ref" => "#/components/schemas/ValidationError")))))
        (rt.auth === :inherit ? api.auth : rt.auth) in (nothing, false) ||
            (op["responses"]["401"] = Dict{String,Any}("description" => "Not authenticated"))
        get!(paths, rstrip(base, '/') * rt.path, Dict{String,Any}())[lowercase(rt.method)] = op
    end
    comps["ValidationError"] = Dict{String,Any}("type" => "object", "properties" => Dict("detail" => Dict("type" => "array",
        "items" => Dict("type" => "object", "properties" => Dict("loc" => Dict("type" => "array"), "msg" => Dict("type" => "string"))))))
    Dict{String,Any}("openapi" => "3.1.0",
                     "info" => Dict{String,Any}("title" => api.title, "version" => api.version, "description" => api.description),
                     "paths" => paths, "components" => Dict{String,Any}("schemas" => comps))
end

swagger_page(api::API, schema_url) = """<!doctype html><html><head><meta charset="utf-8"><title>$(escape_html(api.title))</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css"></head>
<body><div id="swagger-ui"></div><script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({url: $(JSON.json(schema_url)), dom_id: "#swagger-ui"});</script></body></html>"""
