# Django's postgres_tests test_operations, ported (#227): AddIndexConcurrently, RemoveIndexConcurrently,
# CreateExtension, CreateCollation, RemoveCollation, AddConstraintNotValid and ValidateConstraint.
# julia --project=test test/django_postgres_operations.jl   (see setup.jl)
#
# Juango's operations work on tables (`AddIndexConcurrently("pony", index)`) where Django's work on
# models, so their descriptions name the table. Writing, optimizing and the operations' categories run
# on every database; running them, on PostgreSQL (elsewhere they're no-ops or plain AddIndex/AddConstraint).
#
# The routers' allow_migrate with an operation's hints (test_no_allow_migrate, test_allow_migrate_based_on_hints)
# runs on every database: the operation's actions are kept off (or not). Not translated: the query counts of
# CreateExtension (psycopg's type handlers), and test_reduce_add_rename (RenameIndex, #257).
#
# Also not translated, the rest of postgres_tests: test_apps (psycopg type handlers, the migration serializer registry),
# test_app_installed_check (Django's check that django.contrib.postgres is in INSTALLED_APPS; Juango's PostgreSQL
# features need no app) and test_integration (`check` in a subprocess with a settings module). test_introspection
# is in django_inspectdb.jl.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DPO = Juango.Migrations
const DPO_PG = Juango.backend() isa Juango.PostgresBackend
dpo_q(s) = Juango.quote_name(Juango.backend(), s)
dpo_code(ops) = DPO.op_code.(collect(DPO.Operation, ops))
dpo_optimizes_to(ops, expected; before = Juango.SchemaState()) =
    dpo_code(DPO.optimize_operations(collect(DPO.Operation, ops), before, "testapp")) == dpo_code(expected)
"Run operations from state `st` (backwards: undo them), in a transaction or (atomic = false) not; the state after."
function dpo_run!(st, ops...; backwards = false, atomic = true)
    b = Juango.backend()
    states = [st]
    for op in ops
        push!(states, DPO.state_forwards!(op, Juango.copy_state(states[end]), "testapp"))
    end
    actions = Any[]
    for i in (backwards ? (length(ops):-1:1) : (1:length(ops)))
        append!(actions, DPO.op_actions(ops[i], b, states[i], states[i+1], String[]; back = backwards, app = "testapp"))
    end
    atomic ? Juango.schema_atomic(() -> foreach(DPO.run_action, actions)) : foreach(DPO.run_action, actions)
    backwards ? st : states[end]
end
# (routers for #300: Django's NoMigrationRouter and MigrateWhenHinted)
struct DpoNoMigration end
Juango.allow_migrate(::DpoNoMigration, db, app; model = nothing, kw...) = false
struct DpoWhenHinted end
Juango.allow_migrate(::DpoWhenHinted, db, app; model = nothing, kw...) = get(kw, :a_hint, false)
struct DpoPlainRouter end
Juango.allow_migrate(::DpoPlainRouter, db, app; model = nothing) = nothing
struct DpoModelRouter end
Juango.allow_migrate(::DpoModelRouter, db, app; model = nothing) = model === nothing ? nothing : false
"The SQL statements an operation runs (forwards or backwards)."
dpo_sql(op; backwards = false, st = Juango.SchemaState()) =
    [a for a in (backwards ? DPO.backwards : DPO.forwards)(op, Juango.backend(), st, DPO.state_forwards!(op, Juango.copy_state(st), "testapp"), String[])
     if a isa AbstractString]
"Django's set_up_test_model: a `<app>_pony` table (pink, weight), with an index on pink if `index`."
function dpo_ponies(f, app; index = false)
    t = "$(app)_pony"
    ops = DPO.Operation[DPO.CreateModel(t; columns = [Juango.Column("pink", :int; default = 3), Juango.Column("weight", :float)],
                                        indexes = index ? [Juango.Index("pink"; name = "pony_pink_idx")] : Juango.Index[])]
    st = dpo_run!(Juango.SchemaState(), ops...)
    try
        f(st, t)
    finally
        t in Juango.introspect_tables() && Juango.execute("DROP TABLE $(dpo_q(t))")
    end
end
dpo_index(t, cols; type = nothing) = any(v -> v.index && !v.primary_key && v.columns == cols && (type === nothing || v.type == type),
                                         values(Juango.introspect_constraints(t)))
dpo_constraint(t, name) = haskey(Juango.introspect_constraints(t), name)
dpo_insert(t, pink) = Juango.execute("INSERT INTO $(dpo_q(t)) ($(dpo_q("pink")), $(dpo_q("weight"))) VALUES (?, ?)", Any[pink, 1.0])
dpo_collation(name) = DPO_PG && !isempty(Juango.execute("SELECT 1 FROM pg_collation WHERE collname = ?", Any[name]))
dpo_extension(name) = DPO_PG && !isempty(Juango.execute("SELECT 1 FROM pg_extension WHERE extname = ?", Any[name]))
dpo_throws(f, T, msg) = try f(); false catch e; e isa T && occursin(msg, sprint(showerror, e)) end

port_block() do
    @testset "django postgres_tests test_operations: AddIndexConcurrentlyTests" begin
        index = Juango.Index("pink"; name = "pony_pink_idx")
        op = DPO.AddIndexConcurrently("test_add_concurrently_pony", index)
        # test_add (the description, category, name fragment and code)
        @test DPO.describe(op) == "Concurrently create index pony_pink_idx on test_add_concurrently_pony"
        @test DPO.formatted_description(op) == "+ Concurrently create index pony_pink_idx on test_add_concurrently_pony"
        @test DPO.op_code(op) == "AddIndexConcurrently(\"test_add_concurrently_pony\", Index([\"pink\"]; name = \"pony_pink_idx\"))"
        st0 = DPO.state_forwards!(DPO.CreateModel("test_add_concurrently_pony"; columns = [Juango.Column("pink", :int)]), Juango.SchemaState(), "testapp")
        @test length(DPO.state_forwards!(op, Juango.copy_state(st0), "testapp")["test_add_concurrently_pony"].indexes) == 1
        # test_reduce_add_remove_concurrently, test_reduce_add_remove
        pony = DPO.state_forwards!(DPO.CreateModel("Pony"; columns = [Juango.Column("pink", :int)]), Juango.SchemaState(), "testapp")
        @test dpo_optimizes_to([DPO.AddIndexConcurrently("Pony", index), DPO.RemoveIndex("Pony", "pony_pink_idx")], []; before = pony)
        @test dpo_optimizes_to([DPO.AddIndexConcurrently("Pony", index), DPO.RemoveIndexConcurrently("Pony", "pony_pink_idx")], []; before = pony)
        @test dpo_optimizes_to([DPO.AddIndex("Pony", index), DPO.RemoveIndexConcurrently("Pony", "pony_pink_idx")], []; before = pony)

        DPO_PG && dpo_ponies("test_add_concurrently") do st, t
            # test_requires_atomic_false
            @test dpo_throws(() -> dpo_run!(st, DPO.AddIndexConcurrently(t, index)), Juango.NotSupportedError,
                             "The AddIndexConcurrently operation cannot be executed inside a transaction (set atomic = False on the migration).")
            # test_add
            @test !dpo_index(t, ["pink"])
            st2 = dpo_run!(st, DPO.AddIndexConcurrently(t, index); atomic = false)
            @test dpo_index(t, ["pink"])
            dpo_run!(st, DPO.AddIndexConcurrently(t, index); backwards = true, atomic = false)
            @test !dpo_index(t, ["pink"])
            # test_add_other_index_type
            op2 = DPO.AddIndexConcurrently(t, BrinIndex(:pink; name = "pony_pink_brin_idx"))
            dpo_run!(st, op2; atomic = false)
            @test dpo_index(t, ["pink"]; type = "brin")
            dpo_run!(st, op2; backwards = true, atomic = false)
            @test !dpo_index(t, ["pink"])
            # test_add_with_options
            op3 = DPO.AddIndexConcurrently(t, BTreeIndex(:pink; name = "pony_pink_btree_idx", fillfactor = 70))
            dpo_run!(st, op3; atomic = false)
            @test dpo_index(t, ["pink"]; type = "btree")
            dpo_run!(st, op3; backwards = true, atomic = false)
            @test !dpo_index(t, ["pink"])
        end
    end

    @testset "django postgres_tests test_operations: RemoveIndexConcurrentlyTests" begin
        op = DPO.RemoveIndexConcurrently("test_rm_concurrently_pony", "pony_pink_idx")
        # test_remove (the description, category and code)
        @test DPO.describe(op) == "Concurrently remove index pony_pink_idx from test_rm_concurrently_pony"
        @test DPO.formatted_description(op) == "- Concurrently remove index pony_pink_idx from test_rm_concurrently_pony"
        @test DPO.op_code(op) == "RemoveIndexConcurrently(\"test_rm_concurrently_pony\", \"pony_pink_idx\")"
        DPO_PG && dpo_ponies("test_rm_concurrently"; index = true) do st, t
            # test_requires_atomic_false
            @test dpo_throws(() -> dpo_run!(st, op), Juango.NotSupportedError,
                             "The RemoveIndexConcurrently operation cannot be executed inside a transaction (set atomic = False on the migration).")
            # test_remove
            @test isempty(DPO.state_forwards!(op, Juango.copy_state(st), "testapp")[t].indexes)
            @test dpo_index(t, ["pink"])
            dpo_run!(st, op; atomic = false)
            @test !dpo_index(t, ["pink"])
            dpo_run!(st, op; backwards = true, atomic = false)
            @test dpo_index(t, ["pink"])
        end
    end

    @testset "django postgres_tests test_operations: CreateExtensionTests" begin
        op = DPO.CreateExtension("tablefunc")
        @test DPO.formatted_description(op) == "+ Creates extension tablefunc"          # test_no_allow_migrate
        @test DPO.name_fragment(op) == "create_extension_tablefunc"                     # test_allow_migrate
        @test DPO.name_fragment(DPO.BloomExtension()) == "create_extension_bloom"       # test_create_existing_extension
        if DPO_PG
            # test_allow_migrate
            @test occursin("CREATE EXTENSION IF NOT EXISTS", only(dpo_sql(op)))
            @test occursin("DROP EXTENSION IF EXISTS", only(dpo_sql(op; backwards = true)))
            dpo_run!(Juango.SchemaState(), op; atomic = false)
            @test dpo_extension("tablefunc")
            # test_create_existing_extension: installed already, so not created again (it would need privileges)
            @test occursin("SELECT 1 FROM pg_extension", only(dpo_sql(op)))
            dpo_run!(Juango.SchemaState(), op; atomic = false)
            @test dpo_extension("tablefunc")
            dpo_run!(Juango.SchemaState(), op; backwards = true, atomic = false)
            @test !dpo_extension("tablefunc")
            # test_drop_nonexistent_extension
            dpo_run!(Juango.SchemaState(), op; backwards = true, atomic = false)
            @test !dpo_extension("tablefunc")
        else
            @test isempty(dpo_sql(op))
        end
    end

    @testset "django postgres_tests test_operations: CreateCollationTests" begin
        # test_create
        op = DPO.CreateCollation("C_test"; locale = "C")
        @test DPO.name_fragment(op) == "create_collation_c_test"
        @test DPO.describe(op) == "Create collation C_test"
        @test DPO.formatted_description(op) == "+ Create collation C_test"
        @test DPO.op_code(op) == "CreateCollation(\"C_test\", \"C\")"
        @test op == DPO.CreateCollation("C_test", "C")
        if DPO_PG
            @test occursin("CREATE COLLATION", only(dpo_sql(op)))
            dpo_run!(Juango.SchemaState(), op; atomic = false)
            @test dpo_collation("C_test")
            # creating the same collation raises an exception
            @test dpo_throws(() -> dpo_run!(Juango.SchemaState(), op), Exception, "already exists")
            @test occursin("DROP COLLATION", only(dpo_sql(op; backwards = true)))
            dpo_run!(Juango.SchemaState(), op; backwards = true, atomic = false)
            @test !dpo_collation("C_test")
        else
            @test isempty(dpo_sql(op))                                                  # (a no-op elsewhere)
        end
        # test_create_non_deterministic_collation
        op = DPO.CreateCollation("case_insensitive_test", "und-u-ks-level2"; provider = "icu", deterministic = false)
        @test DPO.op_code(op) == "CreateCollation(\"case_insensitive_test\", \"und-u-ks-level2\"; provider = \"icu\", deterministic = false)"
        if DPO_PG
            @test only(dpo_sql(op)) == "CREATE COLLATION \"case_insensitive_test\" (locale=\"und-u-ks-level2\", provider=\"icu\", deterministic=false)"
            dpo_run!(Juango.SchemaState(), op; atomic = false)
            @test dpo_collation("case_insensitive_test")
            dpo_run!(Juango.SchemaState(), op; backwards = true, atomic = false)
            @test !dpo_collation("case_insensitive_test")
        end
        # test_create_collation_alternate_provider
        op = DPO.CreateCollation("german_phonebook_test"; provider = "icu", locale = "de-u-co-phonebk")
        @test DPO.op_code(op) == "CreateCollation(\"german_phonebook_test\", \"de-u-co-phonebk\"; provider = \"icu\")"
        if DPO_PG
            dpo_run!(Juango.SchemaState(), op; atomic = false)
            @test dpo_collation("german_phonebook_test")
            dpo_run!(Juango.SchemaState(), op; backwards = true, atomic = false)
            @test !dpo_collation("german_phonebook_test")
        end
        # test_writer: the migration file brings it back
        op = DPO.CreateCollation("sample_collation", "und-u-ks-level2"; provider = "icu", deterministic = false)
        code = DPO.op_code(op)
        @test code == "CreateCollation(\"sample_collation\", \"und-u-ks-level2\"; provider = \"icu\", deterministic = false)"
        @test Core.eval(DPO, Meta.parse(code)) == op
        # test_reduce_create_remove (whatever the locale)
        @test dpo_optimizes_to([op, DPO.RemoveCollation("sample_collation", "de-u-ks-level1")], [])
        @test dpo_optimizes_to([op, DPO.RemoveCollation("other_collation", "de-u-ks-level1")],
                               [op, DPO.RemoveCollation("other_collation", "de-u-ks-level1")])
    end

    @testset "django postgres_tests test_operations: RemoveCollationTests" begin
        # test_remove
        op = DPO.RemoveCollation("C_test"; locale = "C")
        @test DPO.name_fragment(op) == "remove_collation_c_test"
        @test DPO.describe(op) == "Remove collation C_test"
        @test DPO.formatted_description(op) == "- Remove collation C_test"
        @test DPO.op_code(op) == "RemoveCollation(\"C_test\", \"C\")"
        if DPO_PG
            dpo_run!(Juango.SchemaState(), DPO.CreateCollation("C_test"; locale = "C"); atomic = false)
            @test occursin("DROP COLLATION", only(dpo_sql(op)))
            dpo_run!(Juango.SchemaState(), op; atomic = false)
            @test !dpo_collation("C_test")
            # removing a nonexistent collation raises an exception
            @test dpo_throws(() -> dpo_run!(Juango.SchemaState(), op), Exception, "does not exist")
            @test occursin("CREATE COLLATION", only(dpo_sql(op; backwards = true)))
            dpo_run!(Juango.SchemaState(), op; backwards = true, atomic = false)
            @test dpo_collation("C_test")
            dpo_run!(Juango.SchemaState(), op; atomic = false)
        end
    end

    @testset "django postgres_tests test_operations: AddConstraintNotValidTests" begin
        # test_non_check_constraint_not_supported
        @test dpo_throws(() -> DPO.AddConstraintNotValid("pony", Juango.ConstraintSpec(:unique, "pony_pink_uniq"; columns = ["pink"])),
                         ArgumentError, "AddConstraintNotValid.constraint must be a check constraint.")
        # test_add
        name = "pony_pink_gte_check"
        constraint = Juango.ConstraintSpec(:check, name; condition = Q(pink__gte = 4))
        dpo_ponies("test_add_constraint_not_valid") do st, t
            op = DPO.AddConstraintNotValid(t; constraint = constraint)
            @test DPO.describe(op) == "Create not valid constraint $name on $t"
            @test DPO.formatted_description(op) == "+ Create not valid constraint $name on $t"
            @test DPO.name_fragment(op) == "$(t)_$(name)_not_valid"
            @test DPO.op_code(op) == "AddConstraintNotValid(\"$t\", ConstraintSpec(:check, \"$name\"; condition = Q(:AND, Any[:pink__gte => 4], false)))"
            @test length(DPO.state_forwards!(op, Juango.copy_state(st), "testapp")[t].constraints) == 1
            if DPO_PG
                @test !dpo_constraint(t, name)
                dpo_insert(t, 2)
                st2 = dpo_run!(st, op)                       # (the row already there isn't checked)
                @test dpo_throws(() -> Juango.atomic(() -> dpo_insert(t, 3)), Juango.IntegrityError, "check constraint \"$name\"")
                @test dpo_constraint(t, name)
                dpo_run!(st, op; backwards = true)
                @test !dpo_constraint(t, name)
                dpo_insert(t, 3)
                # ValidateConstraintTests.test_validate
                st2 = dpo_run!(st, op)
                vop = DPO.ValidateConstraint(t; name = name)
                @test DPO.describe(vop) == "Validate constraint $name on $t"
                @test DPO.formatted_description(vop) == "~ Validate constraint $name on $t"
                @test DPO.name_fragment(vop) == "$(t)_validate_$name"
                @test DPO.op_code(vop) == "ValidateConstraint(\"$t\", \"$name\")"
                @test dpo_throws(() -> dpo_run!(st2, vop), Juango.IntegrityError, "check constraint \"$name\"")
                Juango.execute("UPDATE $(dpo_q(t)) SET $(dpo_q("pink")) = 5")
                dpo_run!(st2, vop)
                @test isempty(dpo_sql(vop; backwards = true, st = st2))      # (reversal is a no-op)
            else
                @test !any(s -> occursin("NOT VALID", s), dpo_sql(op; st = st))   # (a plain AddConstraint elsewhere)
                @test isempty(dpo_sql(DPO.ValidateConstraint(t, name); st = st))
            end
        end
    end

    @testset "OperationCategory (formatted_description of the other operations)" begin
        @test DPO.formatted_description(DPO.CreateModel("pony")) == "+ Create model pony (table pony)"
        @test startswith(DPO.formatted_description(DPO.RemoveField("pony", "pink")), "- ")
        @test startswith(DPO.formatted_description(DPO.RenameField("pony", "pink", "blue")), "~ ")
        @test DPO.formatted_description(DPO.RunSQL("SELECT 1", "")) == "s Raw SQL operation"
        @test DPO.formatted_description(DPO.RunJulia(() -> nothing)) == "p Raw Julia operation"
        @test DPO.formatted_description(DPO.SeparateDatabaseAndState()) == "? Custom state/database change combination"
    end

    @testset "django postgres_tests test_operations: the routers' allow_migrate per operation, with hints (#300)" begin
        b, st = Juango.backend(), Juango.SchemaState()
        acts(op; back = false, app = "testapp") = DPO.op_actions(op, b, st, st, String[]; back = back, app = app)
        # test_allow_migrate_based_on_hints: the hints an operation keeps
        @test DPO.CreateExtension("tablefunc").hints == (;)
        hinted = DPO.CreateExtension("tablefunc"; hints = Dict(:a_hint => true))
        @test hinted.hints == (a_hint = true,)
        @test DPO.op_code(hinted) == "CreateExtension(\"tablefunc\"; hints = (a_hint = true,))"
        @test DPO.op_code(DPO.CreateCollation("C_test", "C"; hints = (a_hint = true,))) == "CreateCollation(\"C_test\", \"C\"; hints = (a_hint = true,))"
        @test DPO.op_code(DPO.RunSQL("SELECT 1", ""; hints = (a_hint = true,))) == "RunSQL(Any[\"SELECT 1\"], Any[]; hints = (a_hint = true,))"
        @test DPO.op_code(DPO.RunSQL("SELECT 1", "")) == "RunSQL(Any[\"SELECT 1\"], Any[])"
        @test DPO.RunJulia(() -> nothing; hints = (a_hint = true,)).hints == (a_hint = true,)
        sql = DPO.RunSQL("SELECT 1", "SELECT 2")
        @test !isempty(acts(sql))                                                       # (no routers: everything runs)
        # test_no_allow_migrate (CreateExtensionTests, CreateCollationTests, RemoveCollationTests): nothing, either way
        override_settings(DATABASE_ROUTERS = Any[DpoNoMigration()]) do
            for op in (DPO.CreateExtension("tablefunc"), DPO.CreateCollation("C_test", "C"), DPO.RemoveCollation("C_test", "C"), sql)
                @test isempty(acts(op)) && isempty(acts(op; back = true))
            end
        end
        override_settings(DATABASE_ROUTERS = Any[DpoWhenHinted()]) do
            @test isempty(acts(sql)) && isempty(acts(DPO.CreateExtension("tablefunc")))
            @test !isempty(acts(DPO.RunSQL("SELECT 1", "SELECT 2"; hints = (a_hint = true,))))
            @test !isempty(acts(DPO.RunSQL("SELECT 1", "SELECT 2"; hints = (a_hint = true,)); back = true))
            DPO_PG && @test !isempty(acts(hinted))
        end
        override_settings(DATABASE_ROUTERS = Any[DpoPlainRouter()]) do                 # (a router taking no hints is asked without them)
            @test !isempty(acts(DPO.RunSQL("SELECT 1", "SELECT 2"; hints = (a_hint = true,))))
        end
        # (an operation on a model's table asks with the model, as Django's allow_migrate_model)
        T = first(Juango.all_models()); m = Juango.modelmeta(T)
        @test DPO.op_model(DPO.RemoveIndex(m.table, "x"), m.app) === T && DPO.op_model(sql, m.app) === nothing
        override_settings(DATABASE_ROUTERS = Any[DpoModelRouter()]) do
            @test isempty(acts(DPO.RemoveIndex(m.table, "x"); app = m.app))
            @test !isempty(acts(sql; app = m.app))
        end
    end
end
