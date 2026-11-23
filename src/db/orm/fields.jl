# ORM: fields ---------------------------------------------------------------------------------
#
# The ORM is split over db/orm/: fields.jl, models.jl (registry, @model, instances' properties),
# values.jl (to and from the database), lookups.jl (Q), compiler.jl (SQL), queryset.jl, bulk.jl,
# instances.jl (save!, delete!, validation) and m2m.jl.
#
#     @model struct Post
#         title    = CharField(max_length=200)
#         body     = TextField(blank=true)
#         author   = ForeignKey(Author, on_delete=:CASCADE)
#         created  = DateTimeField(auto_now_add=true)
#         Meta(ordering=["-created"])
#     end
#
#     p = create(Post; title="Hi", author=bob)
#     filter(Post; title__icontains="hi", author__name="Bob") |> order_by("-created")

"Abstract supertype of every model defined with [`@model`](@ref)."
abstract type Model end

struct NoDefault end
const NO_DEFAULT = NoDefault()

"""
Field definition shared by models and forms. Construct with `CharField`,
`IntegerField`, `ForeignKey`, ...
"""
mutable struct Field
    kind::Symbol
    name::Symbol
    null::Bool
    blank::Bool
    default::Any
    unique::Bool
    max_length::Union{Nothing,Int}
    choices::Any        # nothing, a vector of value => label (labels may be lazy), with groups, or a function returning one
    related::Any
    on_delete::Any                    # :CASCADE, :SET_NULL, :PROTECT, :RESTRICT, :SET_DEFAULT, :DO_NOTHING or SET(...)
    related_name::Union{Nothing,Symbol}
    auto_now::Bool
    auto_now_add::Bool
    verbose_name::AbstractString      # may be gettext_lazy(...)
    help_text::Union{AbstractString,SafeString}     # (SafeString: HTML, e.g. the password validators' rules)
    validators::Vector{Any}
    widget::Any                       # nothing, a Symbol (:textarea, :password, ...) or a widget value
    editable::Bool
    db_index::Bool
    model::Any
    through::Any        # ManyToManyField: the intermediate model (generated when not given)
    one_to_one::Bool    # OneToOneField: a unique FK whose reverse side is a single object
    db_default::Any     # value (or Now()) the database fills in when a new row leaves the field out
    generated::Any      # GeneratedField: (expression, persisted) computed by the database
    symmetrical::Bool   # ManyToManyField(:self): a relation in one direction is one in both
    db_comment::Union{Nothing,String}   # a comment on the column in the database
    max_digits::Union{Nothing,Int}      # DecimalField: digits in total
    decimal_places::Union{Nothing,Int}  # DecimalField: digits after the point
    unique_for::Any                     # nothing, or (:date / :month / :year, date field name): unique_for_date = :pub_date
    template_name::Union{Nothing,String}   # forms: the template `as_field_group` renders the field with
    related_query_name::Union{Nothing,Symbol}   # the reverse side's name in lookups (default: related_name, else the model's name)
    error_messages::Union{Nothing,Dict{String,String}}   # code => message, overriding the built-in ones ("required", "invalid", ...)
    db_collation::Union{Nothing,String}   # CharField/TextField: the column's collation
    db_column::Union{Nothing,String}      # the column's name when it isn't the attribute's (Django's db_column, #212)
    to_field::Union{Nothing,Symbol}       # ForeignKey: the related model's unique field it stores (default: its id, #220)
    primary_key::Bool                     # the model's primary key, instead of an automatic id (#221)
    through_fields::Union{Nothing,Tuple{Symbol,Symbol}}   # ManyToManyField: the through model's keys to the owner and the target
    db_constraint::Bool                   # ForeignKey: create the FOREIGN KEY constraint (false: the relation without one)
    form::Union{Nothing,Dict{Symbol,Any}}  # form fields' options that aren't the default (strip, empty_value, disabled, safe_label, no_label)
    att::Symbol         # attname for the name in `attfor` (see `attname`)
    col::String         # string(att): the column name
    attfor::Symbol      # the name `att` and `col` were worked out for
end

# `attname`/`column` are looked up constantly (row loading, attribute access, SQL), so they're
# stored rather than rebuilt each time, and worked out again when the field's name changes.
# (A `setproperty!` method on Field would do it eagerly, but extending Base.setproperty!
# invalidates a large amount of compiled code.)
field_att(kind::Symbol, name::Symbol) = kind === :fk ? Symbol(name, :_id) : name
function refresh_att!(f)
    name = getfield(f, :name)
    a = field_att(getfield(f, :kind), name)
    setfield!(f, :att, a)
    dc = getfield(f, :kind) === :m2m ? nothing : getfield(f, :db_column)     # (a many-to-many keeps its db_table there)
    setfield!(f, :col, dc === nothing ? string(a) : dc)
    setfield!(f, :attfor, name)
    a
end

"The value of a field with `db_default` until the row is saved and the database has filled it in."
struct DatabaseDefault end
const DB_DEFAULT = DatabaseDefault()
Base.show(io::IO, ::DatabaseDefault) = print(io, "DB_DEFAULT")

"""
    SET(value), SET(f)

`on_delete = SET(value)`: when the referenced object is deleted, point at `value` (an object or
a primary key) instead, or at what `f()` returns.
"""
struct OnDeleteSet
    value::Any
end
SET(v) = OnDeleteSet(v)
norm_on_delete(x::OnDeleteSet) = x
function norm_on_delete(x)
    s = Symbol(uppercase(string(x)))
    s in (:CASCADE, :SET_NULL, :PROTECT, :RESTRICT, :SET_DEFAULT, :DO_NOTHING) ||
        throw(ArgumentError("on_delete must be :CASCADE, :SET_NULL, :PROTECT, :RESTRICT, :SET_DEFAULT, :DO_NOTHING or SET(...), not $(repr(x))"))
    s
end

# --- choices ---------------------------------------------------------------------------------------
#
#     @choices Status begin
#         DRAFT = "d", "Draft"                 # value, label (gettext_lazy("Draft") to translate it)
#         PUBLISHED = "p", "Published"
#         ARCHIVED = "a"                       # label from the name: "Archived"
#     end
#     status = CharField(max_length = 1, choices = Status, default = Status.DRAFT)
#     filter(Post; status = Status.PUBLISHED); post.status == Status.DRAFT; post.get_status_display
#
# Choices can also be value => label pairs, grouped (`"Audio" => ["vinyl" => "Vinyl", ...]`), or a
# function returning them, called when they're needed (Django 5's callable choices).

"""
One member of a `@choices` enumeration: `Status.DRAFT.value`, `.label`, `.name`. It equals (and
hashes like) its value, so `post.status == Status.DRAFT` and `filter(Post; status = Status.DRAFT)` work.
"""
struct Choice{T}
    name::Symbol
    value::T
    label::Any              # an AbstractString, possibly a lazy translation
end
Base.:(==)(a::Choice, b::Choice) = a.value == b.value
Base.:(==)(a::Choice, b) = a.value == b
Base.:(==)(a, b::Choice) = a == b.value
Base.:(==)(::Choice, ::Missing) = missing
Base.:(==)(::Missing, ::Choice) = missing
Base.isequal(a::Choice, b::Choice) = isequal(a.value, b.value)
Base.isequal(a::Choice, b) = isequal(a.value, b)
Base.isequal(a, b::Choice) = isequal(a, b.value)
Base.hash(c::Choice, h::UInt) = hash(c.value, h)
adapt_param(b::DatabaseBackend, x::Choice) = adapt_param(b, x.value)     # a query parameter is its value
Base.print(io::IO, c::Choice) = print(io, c.value)
Base.show(io::IO, c::Choice) = print(io, c.name, " (", repr(c.value), " => ", repr(string(c.label)), ")")

"""
    @choices Name begin
        MEMBER = value, label
        OTHER = value                  # label from the name
    end

An enumeration of choices (Django's `TextChoices` / `IntegerChoices`): a constant `Name` whose
members are `Name.MEMBER` (a `Choice`), with `Name.choices` (value => label), `Name.values`,
`Name.labels`, `Name.members` and `Name.label(value)`. Pass it to a field as `choices = Name`.
"""
macro choices(name, block)
    name isa Symbol || error("@choices expects a name: @choices Status begin ... end")
    items = Expr[]
    for ex in block.args
        ex isa LineNumberNode && continue
        (ex isa Expr && ex.head === :(=) && ex.args[1] isa Symbol) || error("@choices: each line is `NAME = value` or `NAME = value, label`")
        m, rhs = ex.args[1], ex.args[2]
        value, label = rhs isa Expr && rhs.head === :tuple ? (rhs.args[1], rhs.args[2]) :
                       (rhs, titlecase(replace(lowercase(string(m)), "_" => " ")))
        push!(items, :($(GlobalRef(@__MODULE__, :Choice))($(QuoteNode(m)), $(esc(value)), $(esc(label)))))
    end
    :(Base.@__doc__ const $(esc(name)) = $(GlobalRef(@__MODULE__, :ChoiceSet))($(QuoteNode(name)), Choice[$(items...)]))
end

"The enumeration `@choices` defines: members by name, plus `choices`, `values`, `labels`, `members`, `label(v)`."
struct ChoiceSet
    name::Symbol
    members::Vector{Choice}
end
function Base.getproperty(cs::ChoiceSet, s::Symbol)
    s in (:name, :members) && return getfield(cs, s)
    ms = getfield(cs, :members)
    s === :choices && return Pair{Any,Any}[m.value => m.label for m in ms]
    s === :values && return [m.value for m in ms]
    s === :labels && return Any[m.label for m in ms]
    s === :label && return v -> choice_label(cs.choices, v)
    i = findfirst(m -> m.name === s, ms)
    i === nothing && throw(ArgumentError("$(getfield(cs, :name)) has no member $s"))
    ms[i]
end
Base.propertynames(cs::ChoiceSet) = (:name, :members, :choices, :values, :labels, :label, (m.name for m in getfield(cs, :members))...)
Base.iterate(cs::ChoiceSet, i = 1) = i > length(getfield(cs, :members)) ? nothing : (getfield(cs, :members)[i], i + 1)
Base.length(cs::ChoiceSet) = length(getfield(cs, :members))
Base.show(io::IO, cs::ChoiceSet) = print(io, getfield(cs, :name), "(", join(string.(m.name for m in getfield(cs, :members)), ", "), ")")

"A choice's label (`v` itself when it isn't one of the choices)."
function choice_label(cs, v)
    cs === nothing && return v
    i = findfirst(c -> value_eq(c.first, v) || string(c.first) == string(v), cs)
    i === nothing ? v : cs[i].second
end

"A group of choices (`\"Audio\" => [\"vinyl\" => \"Vinyl\", ...]`), shown as an optgroup."
struct ChoiceGroup
    label::Any
    choices::Vector{Pair{Any,Any}}
end
choice_pair(c::Choice) = c.value => c.label
choice_pair(c::Pair) = c.first => c.second
choice_pair(c::Tuple{Any,Any}) = c[1] => c[2]                 # ("a", "A"), as Django's
choice_pair(c) = c => string(c)
is_group(c::Tuple{Any,Any}) = is_group(choice_pair(c))      # ("Group", (("1", "One"), ...))
is_group(c) = c isa Pair && (c.second isa AbstractVector || c.second isa AbstractDict || c.second isa Tuple) && !(c.second isa AbstractString)

normchoices(::Nothing) = nothing
normchoices(cs::ChoiceSet) = cs.choices
normchoices(f::Function) = f                                   # called when the choices are needed
# a Dict, as Django's choices = {"Group 1": {1: "First"}, 0: "Other"}: its pairs, groups' too
normchoices(cs::AbstractDict) = normchoices(Any[k => (v isa AbstractDict ? collect(Pair{Any,Any}, v) : v) for (k, v) in cs])
normchoices(cs) = any(is_group, cs) ?
    Any[is_group(c) ? (p = choice_pair(c); ChoiceGroup(p.first, Pair{Any,Any}[choice_pair(x) for x in p.second])) : choice_pair(c) for c in cs] :
    Pair{Any,Any}[choice_pair(c) for c in cs]

"""
    get_blank_choice_label() -> String

The label of a select's empty choice (Django 6.1's): "- Select an option -" (translated), or
"---------" with the `USE_BLANK_CHOICE_DASH` setting.
"""
get_blank_choice_label() = get(settings, :USE_BLANK_CHOICE_DASH, false) === true ? "---------" : gettext("- Select an option -")

"""
    get_choices(field; include_blank = true, limit_choices_to = nothing, ordering = ())

The choices a form would offer for a field, as `value => label` pairs (Django's `Field.get_choices`):
its own choices, or for a foreign key the related objects (`pk => string(obj)`), filtered by
`limit_choices_to` and ordered by `ordering` (else the related model's ordering). A blank choice
(`"" => get_blank_choice_label()`) comes first with `include_blank`, unless the choices have one.
"""
function get_choices(f::Field; include_blank::Bool = true, limit_choices_to = nothing, ordering = ())
    out = Pair{Any,Any}[]
    if f.kind === :fk
        qs = objects(related_model(f))
        limit_choices_to === nothing || (qs = limit_choices_to isa Q ? filter(qs, limit_choices_to) : filter(qs; (Symbol(k) => v for (k, v) in pairs(limit_choices_to))...))
        isempty(ordering) || (qs = order_by(qs, ordering...))
        append!(out, [o.pk => string(o) for o in qs])
    else
        cs = normchoices(f.choices isa Function ? f.choices() : f.choices)
        cs === nothing || append!(out, Any[c isa ChoiceGroup ? (c.label => c.choices) : c for c in cs])
    end
    has_blank = any(c -> c.first == "" || (c.second isa AbstractVector && any(x -> x.first == "", c.second)), out)
    include_blank && !has_blank ? vcat(Pair{Any,Any}["" => get_blank_choice_label()], out) : out
end

"A field's choices in groups: `(group label or nothing, value => label pairs)`."
function choice_groups(f::Field)
    cs = f.choices
    cs === nothing && return nothing
    cs isa Function && (cs = normchoices(cs()))
    out = Tuple{Any,Vector{Pair{Any,Any}}}[]
    for c in cs
        if c isa ChoiceGroup
            push!(out, (c.label, c.choices))
        elseif isempty(out) || out[end][1] !== nothing
            push!(out, (nothing, Pair{Any,Any}[c]))
        else
            push!(out[end][2], c)
        end
    end
    out
end
"A field's choices as one flat list of value => label pairs (nothing without choices)."
field_choices(f::Field) = (g = choice_groups(f); g === nothing ? nothing : Pair{Any,Any}[c for (_, cs) in g for c in cs])

function Field(kind::Symbol; null = false, blank = false, default = NO_DEFAULT, unique = false,
               max_length = nothing, choices = nothing, related = nothing, on_delete = :CASCADE,
               related_name = nothing, auto_now = false, auto_now_add = false, verbose_name = "",
               help_text = "", validators = Any[], widget = nothing, editable = true,
               db_index = false, required = nothing, label = nothing, through = nothing, one_to_one = false,
               db_default = nothing, generated = nothing, symmetrical = false, db_comment = nothing,
               max_digits = nothing, decimal_places = nothing, unique_for_date = nothing, unique_for_month = nothing,
               unique_for_year = nothing, template_name = nothing, related_query_name = nothing, error_messages = nothing,
               min_value = nothing, max_value = nothing, step_size = nothing, min_length = nothing,
               input_formats = nothing, localize::Bool = false, db_collation = nothing, db_column = nothing, to_field = nothing,
               primary_key::Bool = false, through_fields = nothing, db_constraint::Bool = true,
               strip::Bool = true, empty_value = NO_DEFAULT, disabled::Bool = false, label_suffix = nothing, initial = NO_DEFAULT,
               show_hidden_initial::Bool = false, limit_choices_to = nothing, from_db_value = nothing, get_prep_value = nothing)
    initial === NO_DEFAULT || (default = initial)          # (a form field's initial value, Django's name for it)
    required === nothing || (blank = !required)
    # form fields: the date formats to accept, and numbers typed in the language's format ("1.234,5")
    if input_formats !== nothing || localize
        related === nothing || throw(ArgumentError("input_formats and localize are for date, time and number form fields"))
        related = (input_formats = input_formats === nothing ? nothing : collect(input_formats), localize = localize)
    end
    # as Django's form fields: these limits are validators (with codes error_messages can override)
    validators = collect(Any, validators)
    min_length === nothing || pushfirst!(validators, MinLengthValidator(min_length))
    step_size === nothing || pushfirst!(validators, StepValueValidator(step_size; offset = min_value))
    max_value === nothing || pushfirst!(validators, MaxValueValidator(max_value))
    min_value === nothing || pushfirst!(validators, MinValueValidator(min_value))
    fopts = Dict{Symbol,Any}()
    strip || (fopts[:strip] = false)
    empty_value === NO_DEFAULT || (fopts[:empty_value] = empty_value)
    disabled && (fopts[:disabled] = true)
    show_hidden_initial && (fopts[:show_hidden_initial] = true)
    # a foreign key's or many-to-many field's choices in forms: a Q, a dict of lookups, or a function giving either
    limit_choices_to === nothing || (fopts[:limit_choices_to] = limit_choices_to)
    # a custom field (Django's Field subclass overriding from_db_value / get_prep_value): functions applied to each value
    # read from the database (after the kind's own conversion) and to each value before it's written or compared
    from_db_value === nothing || (fopts[:from_db_value] = from_db_value)
    get_prep_value === nothing || (fopts[:get_prep_value] = get_prep_value)
    label isa SafeString && (fopts[:safe_label] = true)          # (a label marked safe is shown as HTML, as Django's mark_safe)
    label isa AbstractString && isempty(label) && (fopts[:no_label] = true)      # (label = "": none at all, as Django's)
    label_suffix === nothing || (fopts[:label_suffix] = string(label_suffix))
    label === nothing || (verbose_name = label isa SafeString ? label.s : string(label))
    if auto_now || auto_now_add
        editable = false
        blank = true
    end
    Field(kind, :_, null, blank, default, unique, max_length, normchoices(choices), related,
          norm_on_delete(on_delete), related_name === nothing ? nothing : Symbol(related_name),
          auto_now, auto_now_add, verbose_name isa AbstractString ? verbose_name : string(verbose_name),
          help_text isa AbstractString ? help_text : string(help_text), collect(Any, validators),
          widget isa Union{AbstractString,Symbol} ? Symbol(widget) : widget, editable, db_index, nothing, through, one_to_one,
          db_default, generated, symmetrical, db_comment === nothing ? nothing : string(db_comment),
          max_digits === nothing ? nothing : Int(max_digits), decimal_places === nothing ? nothing : Int(decimal_places),
          unique_for_date !== nothing ? (:date, Symbol(unique_for_date)) : unique_for_month !== nothing ? (:month, Symbol(unique_for_month)) :
          unique_for_year !== nothing ? (:year, Symbol(unique_for_year)) : nothing,
          template_name === nothing ? nothing : string(template_name),
          related_query_name === nothing ? nothing : Symbol(related_query_name),
          error_messages === nothing ? nothing : Dict{String,String}(string(k) => string(v) for (k, v) in error_messages),
          db_collation === nothing ? nothing : string(db_collation), db_column === nothing ? nothing : string(db_column),
          to_field === nothing || to_field in (:id, :pk, "id", "pk") ? nothing : Symbol(to_field),
          primary_key, through_fields === nothing ? nothing : (Symbol(through_fields[1]), Symbol(through_fields[2])),
          db_constraint, isempty(fopts) ? nothing : fopts,
          field_att(kind, :_), string(field_att(kind, :_)), :_)
end
"A form field's option (`:strip`, `:empty_value`, `:disabled`, `:safe_label`, `:no_label`, `:label_suffix`), or its default."
form_option(f::Field, k::Symbol) = (d = k === :strip ? true : k === :empty_value ? NO_DEFAULT : k === :label_suffix ? nothing : false;
                                    f.form === nothing ? d : get(f.form, k, d))

"""
    GeneratedField(; expression, output_field, db_persist = true)

A column the database computes from other columns of the row, e.g.
`total = GeneratedField(expression = F(:price) * F(:quantity), output_field = FloatField())`.
It can't be assigned; the value is read back after every `save!`. Expressions use `F`,
literals, `+ - * /`, `Lower`, `Upper`, `Length`, `Coalesce` and `Concat`. `db_persist = true`
stores the value (PostgreSQL supports only that); `false` computes it on read.
"""
function GeneratedField(; expression, output_field::Field, db_persist::Bool = true, kw...)
    f = deepcopy(output_field)
    f.generated = (expression isa Expression ? expression : ref(expression), db_persist)
    f.editable = false
    f.blank = true
    f.null = true
    f.default = NO_DEFAULT
    for (k, v) in kw
        setfield!(f, k, v)
    end
    f
end

CharField(; max_length = 255, kw...) = Field(:char; max_length = max_length, kw...)
TextField(; kw...) = Field(:text; kw...)
EmailField(; max_length = 254, kw...) = Field(:email; max_length = max_length, kw...)
"`SlugField(; allow_unicode = true)`: letters and digits of any script too, as Django's."
SlugField(; max_length = 50, allow_unicode::Bool = false, kw...) =
    Field(:slug; max_length = max_length, db_index = true, related = allow_unicode ? (allow_unicode = true,) : nothing, kw...)
URLField(; max_length = 200, kw...) = Field(:url; max_length = max_length, kw...)
"A 32-bit integer (`INTEGER`), validated to -2147483648..2147483647."
IntegerField(; kw...) = Field(:int; kw...)
"A 64-bit integer (`BIGINT`)."
BigIntegerField(; kw...) = Field(:bigint; kw...)
"A 16-bit integer (`SMALLINT`), -32768..32767."
SmallIntegerField(; kw...) = Field(:smallint; kw...)
"An integer from 0 to 2147483647 (`INTEGER` with a check, or `INT UNSIGNED` on MySQL)."
PositiveIntegerField(; kw...) = Field(:posint; kw...)
"An integer from 0 to 9223372036854775807."
PositiveBigIntegerField(; kw...) = Field(:posbigint; kw...)
"An integer from 0 to 32767."
PositiveSmallIntegerField(; kw...) = Field(:possmallint; kw...)

const INT_KINDS = (:int, :bigint, :smallint, :posint, :posbigint, :possmallint)
const INT_RANGES = Dict(:int => (-2147483648, 2147483647), :bigint => (typemin(Int64), typemax(Int64)),
                        :smallint => (-32768, 32767), :posint => (0, 2147483647),
                        :posbigint => (0, typemax(Int64)), :possmallint => (0, 32767))
is_positive_kind(k) = k in (:posint, :posbigint, :possmallint)

"""
    AutoField(), BigAutoField(), SmallAutoField()

The automatic integer primary key's size, for `Meta(pk = AutoField())` or the
`DEFAULT_AUTO_FIELD` setting (`:BigAutoField`, the default, `:AutoField` or `:SmallAutoField`).
"""
struct AutoPK
    kind::Symbol      # :auto (64-bit), :intauto (32-bit), :smallauto (16-bit)
end
AutoField() = AutoPK(:intauto)
BigAutoField() = AutoPK(:auto)
SmallAutoField() = AutoPK(:smallauto)
const AUTO_PK_KINDS = (:auto, :intauto, :smallauto)
is_auto_pk(k) = k in AUTO_PK_KINDS
"The pk kind for `AutoField()`, `:AutoField`, `\"BigAutoField\"` (also dotted, as Django writes it)."
auto_pk_kind(x::AutoPK) = x.kind
function auto_pk_kind(x::Union{Symbol,AbstractString})
    s = string(x)
    n = (i = findlast('.', s)) === nothing ? s : s[i+1:end]
    n == "AutoField" ? :intauto : n == "BigAutoField" ? :auto : n == "SmallAutoField" ? :smallauto :
        throw(ImproperlyConfigured("DEFAULT_AUTO_FIELD must be AutoField, BigAutoField or SmallAutoField, not $(repr(x))"))
end
"The integer column kind of an automatic key (`:bigint` for `:auto`)."
auto_pk_int(k) = k === :intauto ? :int : k === :smallauto ? :smallint : :bigint
FloatField(; kw...) = Field(:float; kw...)
"""
    DecimalField(; max_digits, decimal_places, kw...)

An exact decimal number with at most `max_digits` digits, `decimal_places` of them after the
point: `NUMERIC(max_digits, decimal_places)` in the database. Values are `Decimal`s, rounded to
`decimal_places` when saved and loaded (`price = DecimalField(max_digits = 10, decimal_places = 2)`
holds `dec"19.99"`).
"""
function DecimalField(; max_digits::Union{Nothing,Integer} = nothing, decimal_places::Union{Nothing,Integer} = nothing, kw...)
    # (a form field may leave either out, as Django's; a model's column needs both)
    (max_digits === nothing || max_digits >= 1) && (decimal_places === nothing || decimal_places >= 0) ||
        throw(ArgumentError("DecimalField needs max_digits >= 1 and decimal_places >= 0"))
    max_digits === nothing || decimal_places === nothing || decimal_places <= max_digits ||
        throw(ArgumentError("DecimalField: decimal_places ($decimal_places) can't exceed max_digits ($max_digits)"))
    Field(:decimal; max_digits = max_digits, decimal_places = decimal_places, kw...)
end
# a nullable one starts as NULL, as Django's (a non-nullable one as false, which Django leaves to the form)
# (in a form it must be checked unless required = false, as Django's forms.BooleanField; a model's
# BooleanField in a ModelForm is optional, as Django's formfield())
BooleanField(; null::Bool = false, default = null ? nothing : false, kw...) = Field(:bool; default = default, null = null, kw...)
DateTimeField(; kw...) = Field(:datetime; kw...)
DateField(; kw...) = Field(:date; kw...)
"""
    BinaryField(; max_length = nothing)

Raw bytes (`Vector{UInt8}`): `BYTEA` on PostgreSQL, `LONGBLOB` on MySQL, `BLOB` on SQLite. Not
editable in forms by default; fixtures carry it as base64.
"""
BinaryField(; editable = false, kw...) = Field(:binary; editable = editable, kw...)

"""
    GenericIPAddressField(; protocol = "both", unpack_ipv4 = false)

An IPv4 or IPv6 address, stored as text in its normal form (`::1`, `2001:db8::1`): `INET` on
PostgreSQL, `CHAR(39)` elsewhere. `protocol` is `"both"`, `"IPv4"` or `"IPv6"`; `unpack_ipv4`
turns `::ffff:1.2.3.4` into `1.2.3.4`. A blank value is stored as NULL, so `blank = true` needs
`null = true`.
"""
function GenericIPAddressField(; protocol = "both", unpack_ipv4::Bool = false, kw...)
    p = lowercase(string(protocol))
    p in ("both", "ipv4", "ipv6") || throw(ArgumentError("GenericIPAddressField: protocol must be \"both\", \"IPv4\" or \"IPv6\""))
    unpack_ipv4 && p != "both" && throw(ArgumentError("GenericIPAddressField: unpack_ipv4 needs protocol = \"both\""))
    Field(:ipaddress; related = (protocol = p, unpack_ipv4 = unpack_ipv4), max_length = 39, kw...)
end

"Where a `FilePathField` looks for its choices."
struct FilePathSpec
    path::Any                       # a directory, or a function returning one
    match::Union{Nothing,Regex}     # matched against file names
    recursive::Bool
    allow_files::Bool
    allow_folders::Bool
end
"""
    FilePathField(; path = "", match = nothing, recursive = false, allow_files = true, allow_folders = false, max_length = 100)

A path chosen from the files (and/or folders) under `path` (a directory or a function returning
one) whose names match `match`. Stored as text; forms offer the matching paths as a select.
"""
function FilePathField(; path = "", match = nothing, recursive::Bool = false, allow_files::Bool = true,
                       allow_folders::Bool = false, max_length = 100, kw...)
    (allow_files || allow_folders) || throw(ArgumentError("FilePathField needs allow_files or allow_folders"))
    Field(:filepath; related = FilePathSpec(path, match === nothing ? nothing : match isa Regex ? match : Regex(string(match)),
                                            recursive, allow_files, allow_folders), max_length = max_length, kw...)
end

"The paths a `FilePathField` offers: full path => label (relative to the directory)."
function filepath_choices(f::Field)
    s = f.related
    root = s.path isa Function ? s.path() : string(s.path)
    out = Pair{Any,String}[]
    ok(name) = s.match === nothing || occursin(s.match, name)
    if s.recursive
        for (dir, dirs, files) in walkdir(root)
            s.allow_files && foreach(n -> ok(n) && push!(out, joinpath(dir, n) => relpath(joinpath(dir, n), root)), files)
            s.allow_folders && foreach(n -> ok(n) && push!(out, joinpath(dir, n) => relpath(joinpath(dir, n), root)), dirs)
        end
    else
        for n in readdir(root)
            p = joinpath(root, n)
            ((isdir(p) ? s.allow_folders : s.allow_files) && ok(n)) && push!(out, p => n)
        end
    end
    sort!(out; by = last)
end

"A time of day (`Dates.Time`); `auto_now`/`auto_now_add` use the current time in the current time zone."
TimeField(; kw...) = Field(:time; kw...)
"""
A length of time: a fixed `Period` (`Hour(2)`) or `CompoundPeriod` (`Day(1) + Hour(2)`), read back
as a canonical `CompoundPeriod`. INTERVAL on PostgreSQL, a count of microseconds elsewhere.
"""
DurationField(; kw...) = Field(:duration; kw...)
"""
    ForeignKey(Model; on_delete=:CASCADE, related_name=nothing, kw...)

`Model` may be a type, `:self`, or a `Symbol` naming a model defined later.
`on_delete` is one of `:CASCADE`, `:SET_NULL`, `:PROTECT`, `:DO_NOTHING`.
`to_field = :barcode` stores the related row's `barcode` (a unique field) instead of its id, as
Django's `to_field`: `filter(Well; plate = "P-0001")` then compares barcodes.
`db_constraint = false` (as Django's) creates no FOREIGN KEY constraint: the column may hold keys of
rows that don't exist (a legacy table, rows deleted elsewhere); joins and lookups work as usual.
"""
function ForeignKey(to; on_delete = :CASCADE, kw...)
    f = Field(:fk; related = to, on_delete = on_delete, db_index = true, kw...)
    f.on_delete === :SET_DEFAULT && f.default isa NoDefault &&
        throw(ArgumentError("on_delete = :SET_DEFAULT needs a default for the foreign key"))
    f.on_delete === :SET_NULL && !f.null && throw(ArgumentError("on_delete = :SET_NULL needs null = true"))
    f
end

"""
    OneToOneField(Model; on_delete=:CASCADE, related_name=nothing, kw...)

A foreign key with a unique constraint. The reverse side is a single object (or
`nothing`): `user.profile` instead of a queryset. Its default name is the lower-case
model name.
"""
OneToOneField(to; on_delete = :CASCADE, kw...) =
    Field(:fk; related = to, on_delete = on_delete, unique = true, one_to_one = true, kw...)

"""
    ManyToManyField(Model; related_name=nothing, through=nothing, blank=false, kw...)

A many-to-many relation. Juango creates the join table (`<table>_<field>`, with a unique
pair) unless `through` names your own intermediate model with two foreign keys. Access it
as `post.tags` (a queryset) and change it with `add!`, `remove!`, `set!` and `clear!`.
The other side gets `tag.post_set` (or `related_name`).

A relation of a model to itself (`friends = ManyToManyField(:self)`) is symmetrical: when
`a` is a friend of `b`, `b` is a friend of `a` (adding or removing either way changes both).
Pass `symmetrical = false` for one-way relations such as "follows". A symmetrical relation can have
its own `through` model, as Django's since 3.0: each link is then two of its rows, both given the
`through_defaults`.

`db_table = "post_tag"` names the join table Juango makes (by default the model's table and the field's
name, `blog_post_tags`), as Django's.

A `through` model with more than one foreign key to the same model (an invitation's inviter and
invitee) needs `through_fields = (:event, :invitee)`: its keys to this model and to the related one.
"""
function ManyToManyField(to; symmetrical = nothing, db_table = nothing, kw...)
    sym = something(symmetrical, to === :self)
    sym && to !== :self && throw(ArgumentError("symmetrical = true is for a ManyToManyField(:self)"))
    db_table === nothing || get(kw, :through, nothing) === nothing ||
        throw(ArgumentError("db_table is for the join table Juango makes; with a through model, give it Meta(table = ...)"))
    Field(:m2m; related = to, symmetrical = sym, db_column = db_table === nothing ? nothing : string(db_table), kw...)
end

const STRING_KINDS = (:char, :text, :email, :slug, :url)

"Attribute name under which the raw value is stored (`author_id` for a FK)."
attname(f::Field) = getfield(f, :attfor) === getfield(f, :name) ? getfield(f, :att) : refresh_att!(f)
"The field's column name (`string(attname(f))`)."
column(f::Field) = (attname(f); getfield(f, :col))
label(f::Field) = isempty(f.verbose_name) ? gettext(uppercasefirst(replace(string(f.name), '_' => ' '))) : String(f.verbose_name)
