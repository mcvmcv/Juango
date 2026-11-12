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
    choices::Union{Nothing,Vector{Pair{Any,String}}}
    related::Any
    on_delete::Symbol
    related_name::Union{Nothing,Symbol}
    auto_now::Bool
    auto_now_add::Bool
    verbose_name::AbstractString      # may be gettext_lazy(...)
    help_text::AbstractString
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
    setfield!(f, :col, string(a))
    setfield!(f, :attfor, name)
    a
end

"The value of a field with `db_default` until the row is saved and the database has filled it in."
struct DatabaseDefault end
const DB_DEFAULT = DatabaseDefault()
Base.show(io::IO, ::DatabaseDefault) = print(io, "DB_DEFAULT")

normchoices(::Nothing) = nothing
normchoices(cs) = Pair{Any,String}[c isa Pair ? (c.first => string(c.second)) : (c => string(c)) for c in cs]

function Field(kind::Symbol; null = false, blank = false, default = NO_DEFAULT, unique = false,
               max_length = nothing, choices = nothing, related = nothing, on_delete = :CASCADE,
               related_name = nothing, auto_now = false, auto_now_add = false, verbose_name = "",
               help_text = "", validators = Any[], widget = nothing, editable = true,
               db_index = false, required = nothing, label = nothing, through = nothing, one_to_one = false,
               db_default = nothing, generated = nothing, symmetrical = false, db_comment = nothing,
               max_digits = nothing, decimal_places = nothing)
    required === nothing || (blank = !required)
    label === nothing || (verbose_name = string(label))
    if auto_now || auto_now_add
        editable = false
        blank = true
    end
    Field(kind, :_, null, blank, default, unique, max_length, normchoices(choices), related,
          Symbol(uppercase(string(on_delete))), related_name === nothing ? nothing : Symbol(related_name),
          auto_now, auto_now_add, verbose_name isa AbstractString ? verbose_name : string(verbose_name),
          help_text isa AbstractString ? help_text : string(help_text), collect(Any, validators),
          widget isa Union{AbstractString,Symbol} ? Symbol(widget) : widget, editable, db_index, nothing, through, one_to_one,
          db_default, generated, symmetrical, db_comment === nothing ? nothing : string(db_comment),
          max_digits === nothing ? nothing : Int(max_digits), decimal_places === nothing ? nothing : Int(decimal_places),
          field_att(kind, :_), string(field_att(kind, :_)), :_)
end

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
SlugField(; max_length = 50, kw...) = Field(:slug; max_length = max_length, db_index = true, kw...)
URLField(; max_length = 200, kw...) = Field(:url; max_length = max_length, kw...)
IntegerField(; kw...) = Field(:int; kw...)
FloatField(; kw...) = Field(:float; kw...)
"""
    DecimalField(; max_digits, decimal_places, kw...)

An exact decimal number with at most `max_digits` digits, `decimal_places` of them after the
point: `NUMERIC(max_digits, decimal_places)` in the database. Values are `Decimal`s, rounded to
`decimal_places` when saved and loaded (`price = DecimalField(max_digits = 10, decimal_places = 2)`
holds `dec"19.99"`).
"""
function DecimalField(; max_digits::Integer, decimal_places::Integer, kw...)
    (max_digits >= 1 && decimal_places >= 0) || throw(ArgumentError("DecimalField needs max_digits >= 1 and decimal_places >= 0"))
    decimal_places <= max_digits || throw(ArgumentError("DecimalField: decimal_places ($decimal_places) can't exceed max_digits ($max_digits)"))
    Field(:decimal; max_digits = max_digits, decimal_places = decimal_places, kw...)
end
BooleanField(; default = false, kw...) = Field(:bool; default = default, blank = true, kw...)
DateTimeField(; kw...) = Field(:datetime; kw...)
DateField(; kw...) = Field(:date; kw...)
"""
    ForeignKey(Model; on_delete=:CASCADE, related_name=nothing, kw...)

`Model` may be a type, `:self`, or a `Symbol` naming a model defined later.
`on_delete` is one of `:CASCADE`, `:SET_NULL`, `:PROTECT`, `:DO_NOTHING`.
"""
ForeignKey(to; on_delete = :CASCADE, kw...) = Field(:fk; related = to, on_delete = on_delete, db_index = true, kw...)

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
Pass `symmetrical = false` for one-way relations such as "follows".
"""
function ManyToManyField(to; symmetrical = nothing, kw...)
    sym = something(symmetrical, to === :self)
    sym && to !== :self && throw(ArgumentError("symmetrical = true is for a ManyToManyField(:self)"))
    sym && haskey(kw, :through) && kw[:through] !== nothing &&
        throw(ArgumentError("a symmetrical ManyToManyField can't have a custom through model; use symmetrical = false"))
    Field(:m2m; related = to, symmetrical = sym, kw...)
end

const STRING_KINDS = (:char, :text, :email, :slug, :url)

"Attribute name under which the raw value is stored (`author_id` for a FK)."
attname(f::Field) = getfield(f, :attfor) === getfield(f, :name) ? getfield(f, :att) : refresh_att!(f)
"The field's column name (`string(attname(f))`)."
column(f::Field) = (attname(f); getfield(f, :col))
label(f::Field) = isempty(f.verbose_name) ? gettext(uppercasefirst(replace(string(f.name), '_' => ' '))) : String(f.verbose_name)
