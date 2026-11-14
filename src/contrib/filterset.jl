# FilterSets: declarative filters from GET parameters (in the manner of django-filter) ------------------
#
#     PostFilter(req) = FilterSet(Post, [
#         :title   => CharFilter(lookup = "icontains"),
#         :status  => ChoiceFilter(),                                   # choices from the model field
#         :author  => ModelChoiceFilter(r -> filter(Author; active = true)),   # queryset per request
#         :tags    => ModelMultipleChoiceFilter(objects(Tag)),
#         :created => DateFromToRangeFilter(),                         # created_after, created_before
#         :q       => CharFilter(method = (qs, name, v) -> filter(qs, Q(title__icontains = v) | Q(body__icontains = v))),
#         :o       => OrderingFilter([:created, :title]),
#     ]; data = req.GET, request = req)
#
#     fs = PostFilter(req)
#     page_obj = get_page(Paginator(fs.qs, 20), get(req.GET, "page", "1"))
#
#     {{ filter.form.title }} {{ filter.form.title.errors }} ...  {% querystring page=page_obj.next_page_number %}
#
# Each filter is a form field (blank allowed). A filter whose value is empty, or invalid, is left
# out: the page still lists results, and the form shows the field's error.

"""
    Filter(kind; field_name = nothing, lookup = "exact", exclude = false, method = nothing,
           label = nothing, choices = nothing, queryset = nothing, distinct = false, form_field = nothing)

One filter of a `FilterSet`: usually made with `CharFilter`, `NumberFilter`, `BooleanFilter`,
`ChoiceFilter`, `MultipleChoiceFilter`, `ModelChoiceFilter`, `ModelMultipleChoiceFilter`,
`DateFilter`, `DateTimeFilter`, `DateFromToRangeFilter`, `NumberRangeFilter`, `IsNullFilter` or
`OrderingFilter`.

- `field_name`: the model field (or path, `"author__name"`) it filters; the filter's name by default.
- `lookup`: `exact`, `icontains`, `in`, `gte`, `lte`, `isnull`, `year`, any lookup `filter` takes.
- `exclude = true`: leave out the matching rows instead.
- `method = (qs, name, value) -> qs`: filter in your own way (the value is cleaned).
- `queryset`: for the model-choice filters, a queryset or a function of the request returning one.
- `distinct = true`: `distinct(qs)` after filtering (multi-valued relations).
- `form_field`: a form field of your own instead of the default for the kind.
"""
struct Filter
    kind::Symbol
    field_name::Union{Nothing,String}
    lookup::String
    exclude::Bool
    method::Any
    label::Union{Nothing,String}
    choices::Any
    queryset::Any
    distinct::Bool
    form_field::Any
    ordering::Vector{Pair{String,String}}     # OrderingFilter: field path => label
end
Filter(kind::Symbol; field_name = nothing, lookup = "exact", exclude = false, method = nothing, label = nothing,
       choices = nothing, queryset = nothing, distinct = false, form_field = nothing, ordering = Pair{String,String}[]) =
    Filter(kind, field_name === nothing ? nothing : string(field_name), string(lookup), exclude, method,
           label === nothing ? nothing : string(label), choices, queryset, distinct, form_field, ordering)

"A text filter (`lookup = \"icontains\"`, `\"in\"` with comma-separated values ...)."
CharFilter(; kw...) = Filter(:char; kw...)
"A number filter (`lookup = \"gte\"` ...)."
NumberFilter(; kw...) = Filter(:number; kw...)
"Yes / no / either (`?f=true`, `false`, or empty)."
BooleanFilter(; kw...) = Filter(:boolean; kw...)
"One of the choices: the model field's, or `choices = [value => label, ...]`."
ChoiceFilter(; kw...) = Filter(:choice; kw...)
"Any of several choices (`field__in`)."
MultipleChoiceFilter(; kw...) = Filter(:multichoice; lookup = "in", kw...)
"One related object; `queryset` (or a function of the request) limits the choices."
ModelChoiceFilter(queryset = nothing; kw...) = Filter(:modelchoice; queryset = queryset, kw...)
"Any of several related objects (`field__in`, made distinct)."
ModelMultipleChoiceFilter(queryset = nothing; kw...) = Filter(:modelmultichoice; queryset = queryset, lookup = "in", distinct = true, kw...)
"A date (`lookup = \"gte\"` ...)."
DateFilter(; kw...) = Filter(:date; kw...)
"A date and time (`lookup = \"gte\"` ...)."
DateTimeFilter(; kw...) = Filter(:datetime; kw...)
"Two dates, `<name>_after` and `<name>_before` (either may be empty; the day of `before` is included)."
DateFromToRangeFilter(; kw...) = Filter(:daterange; kw...)
"Two numbers, `<name>_min` and `<name>_max`."
NumberRangeFilter(; kw...) = Filter(:numberrange; kw...)
"Whether a field is empty (`isnull`)."
IsNullFilter(; kw...) = Filter(:boolean; lookup = "isnull", kw...)
"""
    OrderingFilter(fields; field_labels = Dict())

Ordering chosen by a parameter (`?o=-created`, or several: `?o=-created,title`): `fields` lists the
orderable field paths, or `path => parameter value` pairs. Each can be ascending or descending.
"""
function OrderingFilter(fields; field_labels = Dict(), kw...)
    ord = Pair{String,String}[]
    for f in fields
        path, val = f isa Pair ? (string(f.first), string(f.second)) : (string(f), string(f))
        push!(ord, path => val)
    end
    Filter(:ordering; ordering = ord, choices = field_labels, kw...)
end

"""
    FilterSet(model, filters; data = nothing, queryset = objects(model), request = nothing, prefix = "")
    FilterSet(model; fields, data, ...)

Filters for a model's queryset, from GET parameters. `filters` is a list of `name => Filter`;
`fields` generates them from the model's fields: `[:status, :author]` (exact) or
`Dict(:title => ["icontains"], :created => ["gte", "lte"])` (named `created__gte` ...).

`fs.qs` is the filtered queryset (chain anything after it), `fs.form` the bound form to render,
`fs.is_bound` whether any data was given.
"""
mutable struct FilterSet
    model::Any
    filters::Vector{Pair{Symbol,Filter}}
    data::Any
    queryset::Any
    request::Any
    prefix::String
    form::Any
    result::Any
end
function FilterSet(@nospecialize(model::Type{<:Model}), filters::AbstractVector = Pair{Symbol,Filter}[]; fields = nothing,
                   data = nothing, queryset = nothing, request = nothing, prefix = "")
    fs = Pair{Symbol,Filter}[Symbol(k) => v for (k, v) in filters]
    fields === nothing || append!(fs, generated_filters(model, fields))
    FilterSet(model, fs, data, something(queryset, objects(model)), request, string(prefix), nothing, nothing)
end

function Base.getproperty(fs::FilterSet, s::Symbol)
    s === :form && return filterset_form(fs)
    s === :qs && return filterset_qs(fs)
    s === :is_bound && return getfield(fs, :data) !== nothing
    getfield(fs, s)
end
tattr(fs::FilterSet, ::Val{S}) where {S} = S in (:form, :qs, :is_bound) ? getproperty(fs, S) : NOTFOUND

# --- the form -------------------------------------------------------------------------------------------

function filter_model_field(model, name::String)
    segs = split(name, "__")
    M = model
    f = nothing
    for s in segs
        f = findfield(modelmeta(M), Symbol(s))
        f === nothing && return nothing
        f.kind === :fk && (M = related_model(f))
    end
    f
end

filter_label(f::Filter, name) = something(f.label, uppercasefirst(replace(string(name), "__" => " ", "_" => " ")))

"The form fields of one filter: `name => field` pairs (two for the range filters)."
function filter_form_fields(fs::FilterSet, name::Symbol, f::Filter)
    f.form_field === nothing || return [name => f.form_field]
    lbl = filter_label(f, name)
    path = something(f.field_name, string(name))
    mf = filter_model_field(fs.model, path)
    k = f.kind
    if k === :char
        return [name => CharField(max_length = nothing, blank = true, verbose_name = lbl)]
    elseif k === :number
        return [name => (mf !== nothing && mf.kind in INT_KINDS ? BigIntegerField(blank = true, null = true, verbose_name = lbl) :
                         FloatField(blank = true, null = true, verbose_name = lbl))]
    elseif k === :boolean
        return [name => TypedChoiceField(["" => "Unknown", "true" => "Yes", "false" => "No"]; blank = true, empty_value = nothing,
                                         coerce = x -> x == "true", verbose_name = lbl)]
    elseif k in (:choice, :multichoice)
        ch = f.choices !== nothing ? f.choices : mf !== nothing && mf.choices !== nothing ? field_choices(mf) :
             throw(ArgumentError("FilterSet: filter $name needs choices (its model field has none)"))
        pairs_ = Pair{Any,Any}[string(c.first) => c.second for c in normchoices(ch)]
        return [name => (k === :choice ? TypedChoiceField(pairs_; blank = true, empty_value = nothing, verbose_name = lbl) :
                         MultipleChoiceField(pairs_; blank = true, verbose_name = lbl))]
    elseif k in (:modelchoice, :modelmultichoice)
        qs = f.queryset isa Function ? f.queryset(fs.request) : f.queryset
        if qs === nothing
            (mf !== nothing && mf.kind === :fk) || throw(ArgumentError("FilterSet: filter $name needs a queryset"))
            qs = objects(related_model(mf))
        end
        return [name => (k === :modelchoice ? ModelChoiceField(qs; blank = true, verbose_name = lbl) :
                         ModelMultipleChoiceField(qs; blank = true, verbose_name = lbl))]
    elseif k === :date
        return [name => DateField(blank = true, null = true, verbose_name = lbl)]
    elseif k === :datetime
        return [name => DateTimeField(blank = true, null = true, verbose_name = lbl)]
    elseif k === :daterange
        return [Symbol(name, "_after") => DateField(blank = true, null = true, verbose_name = lbl * " from"),
                Symbol(name, "_before") => DateField(blank = true, null = true, verbose_name = lbl * " to")]
    elseif k === :numberrange
        return [Symbol(name, "_min") => FloatField(blank = true, null = true, verbose_name = lbl * " from"),
                Symbol(name, "_max") => FloatField(blank = true, null = true, verbose_name = lbl * " to")]
    elseif k === :ordering
        labels = Dict(string(a) => string(b) for (a, b) in pairs(something(f.choices, Dict())))
        opts = Pair{Any,Any}[]
        for (p, v) in f.ordering
            l = get(labels, v, uppercasefirst(replace(v, "__" => " ", "_" => " ")))
            push!(opts, v => l)
            push!(opts, "-" * v => l * " (descending)")
        end
        return [name => CharField(max_length = nothing, blank = true, verbose_name = something(f.label, "Ordering"), choices = opts)]
    end
    throw(ArgumentError("FilterSet: unknown filter kind $k"))
end

function filterset_form(fs::FilterSet)
    f = getfield(fs, :form)
    f === nothing || return f
    fields = Pair{Symbol,Any}[]
    for (name, flt) in getfield(fs, :filters)
        append!(fields, filter_form_fields(fs, name, flt))
    end
    data = getfield(fs, :data)
    form = Form(fields; data = data === nothing ? nothing : data, prefix = getfield(fs, :prefix), name = "FilterForm")
    if data !== nothing
        is_valid(form)
        # an ordering of several fields (?o=-created,title) is valid when each part is one of them
        for (name, flt) in getfield(fs, :filters)
            flt.kind === :ordering && haskey(form.errors, name) || continue
            raw = strip(string(something(raw_value(form, form.fields[findfirst(x -> x.name === name, form.fields)]), "")))
            allowed = Set(v for (_, v) in flt.ordering)
            if !isempty(raw) && all(t -> lstrip(strip(t), '-') in allowed, split(raw, ','))
                delete!(form.errors, name)
                form.cleaned_data[name] = raw
            end
        end
    end
    setfield!(fs, :form, form)
end

# --- filtering --------------------------------------------------------------------------------------------

"The cleaned value of a form field, or `nothing` when it's empty or invalid (its filter is then left out)."
function filter_value(form, name::Symbol)
    haskey(form.errors, name) && return nothing
    v = get(form.cleaned_data, name, nothing)
    (v === nothing || v == "" || (v isa AbstractVector && isempty(v))) ? nothing : v
end

function apply_lookup(qs, f::Filter, path::String, lookup::String, value)
    key = lookup == "exact" ? Symbol(path) : Symbol(path, "__", lookup)
    q = Q(key => value)
    f.exclude ? exclude(qs, q) : filter(qs, q)
end

function filterset_qs(fs::FilterSet)
    r = getfield(fs, :result)
    r === nothing || return r
    qs = getfield(fs, :queryset)
    if getfield(fs, :data) !== nothing
        form = filterset_form(fs)
        for (name, f) in getfield(fs, :filters)
            qs = apply_filter(qs, form, name, f)
        end
    end
    setfield!(fs, :result, qs)
end

function apply_filter(qs, form, name::Symbol, f::Filter)
    path = something(f.field_name, string(name))
    k = f.kind
    if k === :ordering
        v = filter_value(form, name)
        v === nothing && return qs
        allowed = Dict(val => p for (p, val) in f.ordering)
        terms = String[]
        for t in split(string(v), ',')
            t = strip(t)
            desc = startswith(t, "-")
            p = get(allowed, lstrip(t, '-'), nothing)
            p === nothing || push!(terms, (desc ? "-" : "") * p)
        end
        return isempty(terms) ? qs : order_by(qs, terms...)
    elseif k === :daterange || k === :numberrange
        lo, hi = k === :daterange ? (Symbol(name, "_after"), Symbol(name, "_before")) : (Symbol(name, "_min"), Symbol(name, "_max"))
        a, b = filter_value(form, lo), filter_value(form, hi)
        f.method === nothing || return (a === nothing && b === nothing) ? qs : f.method(qs, name, (a, b))
        # a date range on a datetime field takes the whole of the last day
        dt = k === :daterange && (mf = filter_model_field(form_model_of(form, qs), path); mf !== nothing && mf.kind === :datetime)
        a === nothing || (qs = apply_lookup(qs, f, path, "gte", a))
        b === nothing || (qs = dt ? apply_lookup(qs, f, path, "lt", b + Day(1)) : apply_lookup(qs, f, path, "lte", b))
        return qs
    end
    v = filter_value(form, name)
    v === nothing && return qs
    f.method === nothing || return f.method(qs, name, v)
    if k === :char && f.lookup == "in"
        v = [strip(x) for x in split(v, ',') if !isempty(strip(x))]
        isempty(v) && return qs
    end
    k in (:modelchoice, :modelmultichoice) && (v = v isa AbstractVector ? Any[x.id for x in v] : v.id)
    qs = apply_lookup(qs, f, path, f.lookup, v)
    f.distinct ? distinct(qs) : qs
end
form_model_of(form, qs) = queryset_model(qs)

"Filters generated from model fields: `[:status, :author]` or `Dict(:created => [\"gte\", \"lte\"])`."
function generated_filters(@nospecialize(model::Type{<:Model}), fields)
    spec = fields isa AbstractDict ? [(Symbol(k), String[string(l) for l in v]) for (k, v) in fields] :
           [(Symbol(k), ["exact"]) for k in fields]
    out = Pair{Symbol,Filter}[]
    for (name, lookups) in spec
        mf = findfield(modelmeta(model), name)
        mf === nothing && throw(ArgumentError("FilterSet: $(nameof(model)) has no field $name"))
        for l in lookups
            fname = l == "exact" ? name : Symbol(name, "__", l)
            f = if l == "isnull"
                IsNullFilter(field_name = name)
            elseif mf.kind === :fk
                l == "in" ? ModelMultipleChoiceFilter(field_name = name) : ModelChoiceFilter(field_name = name)
            elseif mf.choices !== nothing
                l == "in" ? MultipleChoiceFilter(field_name = name) : ChoiceFilter(field_name = name, lookup = l)
            elseif mf.kind === :bool
                BooleanFilter(field_name = name, lookup = l)
            elseif mf.kind in INT_KINDS || mf.kind in (:float, :decimal)
                NumberFilter(field_name = name, lookup = l)
            elseif mf.kind === :date
                l in ("year", "month", "day") ? NumberFilter(field_name = name, lookup = l) : DateFilter(field_name = name, lookup = l)
            elseif mf.kind === :datetime
                l in ("year", "month", "day") ? NumberFilter(field_name = name, lookup = l) :
                    l == "date" ? DateFilter(field_name = name, lookup = l) : DateTimeFilter(field_name = name, lookup = l)
            else
                CharFilter(field_name = name, lookup = l)
            end
            push!(out, fname => f)
        end
    end
    out
end
