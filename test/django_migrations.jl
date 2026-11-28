# Django's migrations tests, ported (#227): tests/migrations.
# julia --project=test test/django_migrations.jl   (see setup.jl)
#
# Juango's migrations work on tables and columns (`CreateModel("foo"; columns = [...])`) where
# Django's work on models and fields, and they carry no model options, managers or bases (an
# inheritance parent is a table). Each test keeps its Django name in a comment; tests about
# things Juango's migrations don't have are listed at the end of each testset.
# migrations2 and custom_migration_operations are fixtures of these tests (a second app's migrations, operations
# defined in a project), not tests of their own: the tests that use them are translated here, or listed as not.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DM = Juango.Migrations
dmcol(name, kind = :int; kw...) = Juango.Column(name, kind; kw...)
dmstr(name) = Juango.Column(name, :string; max_length = 255)
"A migration state with these tables already in it, for operations on existing tables."
function dm_state(tables::Pair...; app = "testapp")
    st = Juango.SchemaState()
    for (t, cols) in tables
        DM.state_forwards!(DM.CreateModel(t; columns = cols), st, app)
    end
    st
end
# Django's assertOptimizesTo / assertDoesNotOptimize, comparing the operations as migration code
dmcode(ops) = DM.op_code.(collect(DM.Operation, ops))
dmopt(ops; before = Juango.SchemaState(), app = "testapp") =
    dmcode(DM.optimize_operations(collect(DM.Operation, ops), before, app))
optimizes_to(ops, expected; kw...) = dmopt(ops; kw...) == dmcode(expected)
does_not_optimize(ops; kw...) = optimizes_to(ops, ops; kw...)

@testset "django migrations: test_optimizer" begin
    pony = "pony" => [dmcol("weight"), dmcol("pink"), dmcol("age")]
    foo = "foo" => [dmstr("name"), dmcol("age"), dmcol("a"), dmcol("b"), dmcol("c")]
    # test_single
    @test optimizes_to([DM.DeleteModel("foo")], [DM.DeleteModel("foo")]; before = dm_state(foo))
    # test_create_delete_model
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.DeleteModel("foo")], [])
    # test_create_rename_model (CreateModel absorbs RenameModel; the model keeps its name)
    @test optimizes_to([DM.CreateModel("foo"; model = "Foo", columns = [dmstr("name")]), DM.RenameModel("foo", "bar")],
                       [DM.CreateModel("bar"; model = "Foo", columns = [dmstr("name")])])
    # test_rename_model_self
    @test optimizes_to([DM.RenameModel("foo", "baa"), DM.RenameModel("baa", "bar")], [DM.RenameModel("foo", "bar")];
                       before = dm_state(foo))
    @test optimizes_to([DM.RenameModel("foo", "baa"), DM.RenameModel("baa", "foo")], []; before = dm_state(foo))
    # test_create_alter_model_table (AlterModelTable is a RenameModel)
    @test optimizes_to([DM.CreateModel("foo"), DM.RenameModel("foo", "woohoo")], [DM.CreateModel("woohoo"; model = "foo")])
    # test_create_alter_model_table_comment
    @test optimizes_to([DM.CreateModel("foo"), DM.AlterModelTableComment("foo", "A lovely table.")],
                       [DM.CreateModel("foo"; comment = "A lovely table.")])
    # test_create_alter_unique_delete_model
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmcol("a"), dmcol("b")]), DM.RenameModel("foo", "woohoo"),
                        DM.AlterUniqueTogether("woohoo", [["a", "b"]]), DM.DeleteModel("woohoo")], [])
    # test_alter_alter_table_model
    @test optimizes_to([DM.RenameModel("foo", "a"), DM.RenameModel("a", "b")], [DM.RenameModel("foo", "b")]; before = dm_state(foo))
    # test_alter_alter_unique_model
    @test optimizes_to([DM.AlterUniqueTogether("foo", [["a", "b"]]), DM.AlterUniqueTogether("foo", [["a", "c"]])],
                       [DM.AlterUniqueTogether("foo", [["a", "c"]])]; before = dm_state(foo))
    # (as test_alter_alter_*: the last table comment wins)
    @test optimizes_to([DM.AlterModelTableComment("foo", "a"), DM.AlterModelTableComment("foo", "b")],
                       [DM.AlterModelTableComment("foo", "b")]; before = dm_state(foo))
    # test_alter_alter_field
    @test optimizes_to([DM.AlterField("foo", dmcol("name")), DM.AlterField("foo", dmcol("name"; null = true))],
                       [DM.AlterField("foo", dmcol("name"; null = true))]; before = dm_state(foo))

    # test_optimize_through_create
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.CreateModel("bar"; columns = [dmcol("size")]),
                        DM.DeleteModel("foo")], [DM.CreateModel("bar"; columns = [dmcol("size")])])
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.CreateModel("bar"; columns = [dmcol("size")]),
                        DM.DeleteModel("bar"), DM.DeleteModel("foo")], [])
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.CreateModel("bar"; columns = [dmcol("size")]),
                        DM.DeleteModel("foo"), DM.DeleteModel("bar")], [])
    @test optimizes_to([DM.CreateModel("book"; columns = [dmstr("name")]), DM.CreateModel("person"; columns = [dmstr("name")]),
                        DM.AddField("book", dmcol("author", :fk; references = "person")),
                        DM.CreateModel("review"; columns = [dmcol("book", :fk; references = "book")]),
                        DM.CreateModel("reviewer"; columns = [dmstr("name")]),
                        DM.AddField("review", dmcol("reviewer", :fk; references = "reviewer")),
                        DM.RemoveField("book", "author"), DM.DeleteModel("person")],
                       [DM.CreateModel("book"; columns = [dmstr("name")]), DM.CreateModel("reviewer"; columns = [dmstr("name")]),
                        DM.CreateModel("review"; columns = [dmcol("book", :fk; references = "book"), dmcol("reviewer", :fk; references = "reviewer")])])
    # test_create_model_add_field
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.AddField("foo", dmcol("age"))],
                       [DM.CreateModel("foo"; columns = [dmstr("name"), dmcol("age")])])
    # test_create_model_reordering
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.CreateModel("link"; columns = [dmcol("url", :text)]),
                        DM.AddField("foo", dmcol("link", :fk; references = "link"))],
                       [DM.CreateModel("link"; columns = [dmcol("url", :text)]),
                        DM.CreateModel("foo"; columns = [dmstr("name"), dmcol("link", :fk; references = "link")])])
    # test_create_model_reordering_circular_fk: Juango adds a migration's foreign keys once its tables
    # exist, so both fold into their CreateModels (Django keeps one AddField)
    @test optimizes_to([DM.CreateModel("bar"; columns = [dmcol("url", :text)]), DM.CreateModel("foo"; columns = [dmstr("name")]),
                        DM.AddField("bar", dmcol("foo_fk", :fk; references = "foo")), DM.AddField("foo", dmcol("bar_fk", :fk; references = "bar"))],
                       [DM.CreateModel("foo"; columns = [dmstr("name"), dmcol("bar_fk", :fk; references = "bar")]),
                        DM.CreateModel("bar"; columns = [dmcol("url", :text), dmcol("foo_fk", :fk; references = "foo")])])
    # test_create_model_no_reordering_for_unrelated_fk
    @test does_not_optimize([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.CreateModel("link"; columns = [dmcol("url", :text)]),
                             DM.AddField("other", dmcol("link", :fk; references = "link"))]; before = dm_state("other" => [dmstr("x")]))
    # test_create_model_no_reordering_of_inherited_model
    @test optimizes_to([DM.CreateModel("other"; columns = [dmstr("foo")]), DM.CreateModel("parentmodel"; columns = [dmstr("bar")]),
                        DM.CreateModel("childmodel"; columns = [dmstr("baz")], parent = "parentmodel"),
                        DM.AddField("other", dmcol("fk", :fk; references = "childmodel"))],
                       [DM.CreateModel("parentmodel"; columns = [dmstr("bar")]),
                        DM.CreateModel("childmodel"; columns = [dmstr("baz")], parent = "parentmodel"),
                        DM.CreateModel("other"; columns = [dmstr("foo"), dmcol("fk", :fk; references = "childmodel")])])
    # test_create_model_alter_field
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.AlterField("foo", dmcol("name"))],
                       [DM.CreateModel("foo"; columns = [dmcol("name")])])
    # test_create_model_rename_field
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.RenameField("foo", "name", "title")],
                       [DM.CreateModel("foo"; columns = [dmstr("title")])])
    # test_add_field_rename_field
    @test optimizes_to([DM.AddField("foo", dmstr("title2")), DM.RenameField("foo", "title2", "title")],
                       [DM.AddField("foo", dmstr("title"))]; before = dm_state(foo))
    # test_alter_field_rename_field
    @test optimizes_to([DM.AlterField("foo", dmstr("name")), DM.RenameField("foo", "name", "title"), DM.RenameField("foo", "title", "nom")],
                       [DM.RenameField("foo", "name", "nom"), DM.AlterField("foo", dmstr("nom"))]; before = dm_state(foo))
    # test_swapping_fields_names
    @test does_not_optimize([DM.CreateModel("mymodel"; columns = [dmcol("field_a"), dmcol("field_b")]), DM.RunSQL("SELECT 1", ""),
                             DM.RenameField("mymodel", "field_a", "field_c"), DM.RenameField("mymodel", "field_b", "field_a"),
                             DM.RenameField("mymodel", "field_c", "field_b")])
    # (a barrier keeps what comes after it out of an earlier CreateModel: the code sees the table as it was)
    @test does_not_optimize([DM.CreateModel("mymodel"; columns = [dmcol("field_a")]), DM.RunSQL("UPDATE mymodel SET field_a = 1", ""),
                             DM.AddField("mymodel", dmcol("field_b"))])
    # (a table created again under the name of one deleted first isn't moved before the DeleteModel)
    @test does_not_optimize([DM.DeleteModel("foo"), DM.CreateModel("foo"; columns = [dmcol("x")])]; before = dm_state(foo))
    # test_create_model_remove_field
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name"), dmcol("age")]), DM.RemoveField("foo", "age")],
                       [DM.CreateModel("foo"; columns = [dmstr("name")])])
    # test_add_field_alter_field
    @test optimizes_to([DM.AddField("foo", dmcol("age2")), DM.AlterField("foo", dmcol("age2", :float; default = 2.4))],
                       [DM.AddField("foo", dmcol("age2", :float; default = 2.4))]; before = dm_state(foo))
    # test_add_field_delete_field
    @test optimizes_to([DM.AddField("foo", dmcol("age2")), DM.RemoveField("foo", "age2")], []; before = dm_state(foo))
    # test_alter_field_delete_field
    @test optimizes_to([DM.AlterField("foo", dmcol("age"; null = true)), DM.RemoveField("foo", "age")],
                       [DM.RemoveField("foo", "age")]; before = dm_state(foo))
    # test_create_alter_unique_field
    ab = [dmcol("a"), dmcol("b")]
    @test optimizes_to([DM.CreateModel("foo"; columns = ab), DM.AlterUniqueTogether("foo", [["a", "b"]]), DM.AddField("foo", dmcol("c"))],
                       [DM.CreateModel("foo"; columns = [ab; dmcol("c")], unique_together = [["a", "b"]])])
    @test optimizes_to([DM.CreateModel("foo"; columns = ab), DM.AlterUniqueTogether("foo", [["a", "b"]]), DM.AlterField("foo", dmstr("b"))],
                       [DM.CreateModel("foo"; columns = [dmcol("a"), dmstr("b")], unique_together = [["a", "b"]])])
    @test optimizes_to([DM.CreateModel("foo"; columns = ab), DM.AlterUniqueTogether("foo", [["a", "b"]]), DM.RenameField("foo", "b", "c")],
                       [DM.CreateModel("foo"; columns = [dmcol("a"), dmcol("c")], unique_together = [["a", "c"]])])
    @test optimizes_to([DM.CreateModel("foo"; columns = ab), DM.AlterUniqueTogether("foo", [["a", "b"]]), DM.RenameField("foo", "b", "x"),
                        DM.RenameField("foo", "x", "c")],
                       [DM.CreateModel("foo"; columns = [dmcol("a"), dmcol("c")], unique_together = [["a", "c"]])])
    @test optimizes_to([DM.CreateModel("foo"; columns = [ab; dmcol("c")]), DM.AlterUniqueTogether("foo", [["a", "b"]]), DM.RemoveField("foo", "c")],
                       [DM.CreateModel("foo"; columns = ab, unique_together = [["a", "b"]])])
    # test_optimize_through_fields
    @test optimizes_to([DM.CreateModel("foo"; columns = [dmstr("name")]), DM.CreateModel("bar"; columns = [dmcol("size")]),
                        DM.AddField("foo", dmcol("age")), DM.AddField("bar", dmcol("width")), DM.AlterField("foo", dmcol("age")),
                        DM.RenameField("bar", "size", "dimensions"), DM.RemoveField("foo", "age"), DM.RenameModel("foo", "phou"),
                        DM.RemoveField("bar", "dimensions"), DM.RenameModel("phou", "fou"), DM.DeleteModel("fou")],
                       [DM.CreateModel("bar"; columns = [dmcol("width")])])
    # test_add_remove_index
    @test optimizes_to([DM.AddIndex("pony", Juango.Index("weight", "pink"; name = "idx_pony_weight_pink")),
                        DM.RemoveIndex("pony", "idx_pony_weight_pink")], []; before = dm_state(pony))
    # test_add_remove_constraint
    gt = Juango.ConstraintSpec(:check, "constraint_pony_pink_gt_2"; condition = Q(pink__gt = 2))
    @test optimizes_to([DM.AddConstraint("pony", gt), DM.RemoveConstraint("pony", "constraint_pony_pink_gt_2")], []; before = dm_state(pony))
    @test does_not_optimize([DM.AddConstraint("pony", gt), DM.RemoveConstraint("pony", "other_name")];
                            before = dm_state("pony" => [dmcol("pink")], ) |> st -> (DM.state_forwards!(DM.AddConstraint("pony",
                                Juango.ConstraintSpec(:check, "other_name"; condition = Q(pink__gt = 0))), st, "testapp"); st))
    # test_create_model_add_index
    @test optimizes_to([DM.CreateModel("pony"; columns = [dmcol("weight"), dmcol("age")], indexes = [Juango.Index("age"; name = "idx_pony_age")]),
                        DM.AddIndex("pony", Juango.Index("weight"; name = "idx_pony_weight"))],
                       [DM.CreateModel("pony"; columns = [dmcol("weight"), dmcol("age")],
                                       indexes = [Juango.Index("age"; name = "idx_pony_age"), Juango.Index("weight"; name = "idx_pony_weight")])])
    # test_create_model_remove_index
    @test optimizes_to([DM.CreateModel("pony"; columns = [dmcol("weight"), dmcol("age")],
                                       indexes = [Juango.Index("age"; name = "idx_pony_age"), Juango.Index("weight"; name = "idx_pony_weight")]),
                        DM.RemoveIndex("pony", "idx_pony_age")],
                       [DM.CreateModel("pony"; columns = [dmcol("weight"), dmcol("age")], indexes = [Juango.Index("weight"; name = "idx_pony_weight")])])
    # test_create_model_add_constraint
    wgt = Juango.ConstraintSpec(:check, "pony_weight_gt_0"; condition = Q(weight__gt = 0))
    wu = Juango.ConstraintSpec(:unique, "pony_weight_unique"; columns = ["weight"])
    @test optimizes_to([DM.CreateModel("pony"; columns = [dmcol("weight")]), DM.AddConstraint("pony", wgt)],
                       [DM.CreateModel("pony"; columns = [dmcol("weight")], constraints = [wgt])])
    # test_create_model_remove_constraint
    @test optimizes_to([DM.CreateModel("pony"; columns = [dmcol("weight")], constraints = [wgt, wu]), DM.RemoveConstraint("pony", "pony_weight_gt_0")],
                       [DM.CreateModel("pony"; columns = [dmcol("weight")], constraints = [wu])])
    # test_rename_index, test_add_rename_index, test_create_model_rename_index_no_old_fields: RenameIndex (#257)
    @test_broken isdefined(DM, :RenameIndex)
    # test_optimize_elidable_operation: elidable RunSQL/RunJulia (#258)
    @test_broken :elidable in fieldnames(DM.RunSQL)
    # not translated: test_none_app_label (app labels are strings); test_create_alter_model_options,
    # test_create_alter_model_managers, test_create_model_and_remove_model_options (no options or managers
    # in migrations); test_create_alter_index_delete_model, test_create_alter_index_field,
    # test_alter_alter_index_model (index_together is gone from Django); test_create_alter_owrt_delete_model,
    # test_create_alter_owrt_field, test_alter_alter_owrt_model (no order_with_respect_to);
    # test_create_model_add_field_not_through_m2m_through (a through table is an ordinary table);
    # test_multiple_alter_constraints, test_alter_remove_constraint, test_add_alter_constraint,
    # test_create_model_alter_constraint (AlterConstraint changes a violation message, which Juango
    # keeps on the model, not in migrations); the foreign-key and bases cases of
    # test_optimize_through_create that refer to models of other apps by label
end

# --- test_operations: each operation run against the database, forwards and backwards ---------------

"Run operations against the database from state `st` (backwards: undo them); the state after (or `st`)."
function dm_run!(st, ops...; backwards = false, app = "testapp")
    b = Juango.backend()
    states = [st]
    for op in ops
        push!(states, DM.state_forwards!(op, Juango.copy_state(states[end]), app))
    end
    deferred, actions = String[], Any[]
    for i in (backwards ? (length(ops):-1:1) : (1:length(ops)))
        append!(actions, DM.op_actions(ops[i], b, states[i], states[i+1], deferred; back = backwards, app = app))   # (as the routers allow)
    end
    append!(actions, deferred)
    b isa Juango.PostgresBackend && (actions = DM.settle_deferred_triggers(actions))
    Juango.schema_atomic(() -> foreach(DM.run_action, actions))
    backwards ? st : states[end]
end
dm_tables() = Set(Juango.introspect_tables())
dm_cols(t) = Dict(c.name => c for c in Juango.introspect_columns(t))
dm_cons(t) = Juango.introspect_constraints(t)
dm_index(t, cols; unique = nothing) =
    any(v -> v.index && !v.primary_key && v.columns == cols && (unique === nothing || v.unique == unique), values(dm_cons(t)))
dm_unique(t, cols) = any(v -> v.unique && !v.primary_key && v.columns == cols, values(dm_cons(t)))
dm_fk(t, col, ft) = any(v -> v.foreign_key !== nothing && v.columns == [col] && v.foreign_key[1] == ft, values(dm_cons(t)))
dm_named(t, name) = haskey(dm_cons(t), name)
dm_fails(f) = try Juango.atomic(f); false catch e; e isa Juango.IntegrityError || e isa Exception end
dm_insert(t, pairs...) = Juango.execute("INSERT INTO $(Juango.quote_name(Juango.backend(), t)) (" *
                                        join((Juango.quote_name(Juango.backend(), string(k)) for (k, _) in pairs), ", ") * ") VALUES (" *
                                        join(("?" for _ in pairs), ", ") * ")", Any[v for (_, v) in pairs])
dm_count(t) = Int(only(Juango.execute("SELECT COUNT(*) AS n FROM $(Juango.quote_name(Juango.backend(), t))"))[:n])
dm_mysql() = Juango.backend() isa Juango.MySQLBackend
"Django's set_up_test_model: a pony table (pink, weight) and, with `rider`, a rider table pointing at it."
dm_pony_ops(p; rider = false, columns = [dmcol("pink"; default = 3), dmcol("weight", :float)], kw...) =
    DM.Operation[DM.CreateModel("$(p)_pony"; columns = columns, kw...);
                 rider ? [DM.CreateModel("$(p)_rider"; columns = [dmcol("pony_id", :fk; references = "$(p)_pony"),
                                                                  dmcol("friend_id", :fk; references = "$(p)_rider", null = true)])] : []]
function with_ponies(f, p; kw...)
    ops = dm_pony_ops(p; kw...)
    st = dm_run!(Juango.SchemaState(), ops...)
    try
        f(st)
    finally
        for t in ["$(p)_rider", "$(p)_horserider", "$(p)_pony", "$(p)_horse"]
            t in dm_tables() && Juango.execute("DROP TABLE $(Juango.quote_name(Juango.backend(), t))")
        end
    end
end

@testset "django migrations: test_operations" begin
    # test_create_model
    op = DM.CreateModel("tcm_pony"; model = "Pony", columns = [dmcol("pink"; default = 1)])
    @test DM.describe(op) == "Create model Pony (table tcm_pony)"
    st = dm_run!(Juango.SchemaState(), op)
    @test [c.name for c in st["tcm_pony"].columns] == ["pink"]
    @test "tcm_pony" in dm_tables() && issubset(["id", "pink"], keys(dm_cols("tcm_pony")))
    dm_run!(Juango.SchemaState(), op; backwards = true)
    @test !("tcm_pony" in dm_tables())
    # test_create_model_with_duplicate_field_name
    @test_throws "Found duplicate value pink in CreateModel fields argument." DM.CreateModel("p"; columns = [dmcol("pink"), dmcol("pink")])
    # test_create_model_m2m (the join table is an ordinary table with two foreign keys)
    with_ponies("tcmm") do st
        st2 = dm_run!(st, DM.CreateModel("tcmm_stable"),
                      DM.CreateModel("tcmm_stable_ponies"; columns = [dmcol("stable_id", :fk; references = "tcmm_stable"),
                                                                      dmcol("pony_id", :fk; references = "tcmm_pony")], unique_together = [["stable_id", "pony_id"]]))
        @test dm_fk("tcmm_stable_ponies", "stable_id", "tcmm_stable") && dm_fk("tcmm_stable_ponies", "pony_id", "tcmm_pony")
        @test dm_unique("tcmm_stable_ponies", ["stable_id", "pony_id"])
        dm_run!(st, DM.CreateModel("tcmm_stable"), DM.CreateModel("tcmm_stable_ponies"; columns = [dmcol("stable_id", :fk; references = "tcmm_stable"),
                    dmcol("pony_id", :fk; references = "tcmm_pony")], unique_together = [["stable_id", "pony_id"]]); backwards = true)
        @test isempty(intersect(dm_tables(), ["tcmm_stable", "tcmm_stable_ponies"]))
    end
    # test_create_model_inheritance (multi-table: the child's key is a foreign key to the parent's)
    with_ponies("tcmi") do st
        op = DM.CreateModel("tcmi_shetland"; columns = [dmcol("cuteness")], parent = "tcmi_pony")
        dm_run!(st, op)
        @test dm_fk("tcmi_shetland", "id", "tcmi_pony")
        dm_run!(st, op; backwards = true)
        @test !("tcmi_shetland" in dm_tables())
    end
    # test_create_model_with_constraint
    gt2 = Juango.ConstraintSpec(:check, "test_crmo_pony_pink_gt_2"; condition = Q(pink__gt = 2))
    op = DM.CreateModel("tcmc_pony"; columns = [dmcol("pink"; default = 3)], constraints = [gt2])
    dm_run!(Juango.SchemaState(), op)
    @test dm_named("tcmc_pony", "test_crmo_pony_pink_gt_2") && dm_cons("tcmc_pony")["test_crmo_pony_pink_gt_2"].check
    dm_insert("tcmc_pony", :pink => 3)
    @test dm_fails(() -> dm_insert("tcmc_pony", :pink => 1))
    dm_run!(Juango.SchemaState(), op; backwards = true)
    # test_create_model_with_partial_unique_constraint (MySQL has no partial indexes: it's left out there, as Django's)
    pu = Juango.ConstraintSpec(:unique, "test_crmo_pony_pink_partial"; columns = ["pink"], condition = Q(weight__gt = 5))
    op = DM.CreateModel("tcmp_pony"; columns = [dmcol("pink"), dmcol("weight", :float)], constraints = [pu])
    dm_run!(Juango.SchemaState(), op)
    dm_insert("tcmp_pony", :pink => 1, :weight => 4.0); dm_insert("tcmp_pony", :pink => 1, :weight => 4.0); dm_insert("tcmp_pony", :pink => 1, :weight => 6.0)
    @test dm_fails(() -> dm_insert("tcmp_pony", :pink => 1, :weight => 7.0)) != dm_mysql()
    dm_run!(Juango.SchemaState(), op; backwards = true)
    # test_create_model_with_deferred_unique_constraint: PostgreSQL checks it at commit (a plain unique index elsewhere)
    du = Juango.ConstraintSpec(:unique, "deferrable_pink_constraint"; columns = ["pink"], deferrable = "deferred")
    op = DM.CreateModel("tcmd_pony"; columns = [dmcol("pink"), dmcol("weight", :float)], constraints = [du])
    @test occursin("deferrable = \"deferred\"", Juango.constraint_code(du))
    dm_run!(Juango.SchemaState(), op)
    dm_insert("tcmd_pony", :pink => 1, :weight => 4.0)
    @test dm_fails(() -> dm_insert("tcmd_pony", :pink => 1, :weight => 4.0))
    if Juango.backend() isa Juango.PostgresBackend
        Juango.atomic() do                                       # (a duplicate fixed before the commit)
            dm_insert("tcmd_pony", :pink => 2, :weight => 1.0); dm_insert("tcmd_pony", :pink => 2, :weight => 2.0)
            Juango.execute("DELETE FROM tcmd_pony WHERE weight = 2.0")
        end
        @test dm_count("tcmd_pony") == 2
        @test dm_fails(() -> (dm_insert("tcmd_pony", :pink => 3, :weight => 1.0); dm_insert("tcmd_pony", :pink => 3, :weight => 2.0);
                              Juango.execute("SET CONSTRAINTS \"deferrable_pink_constraint\" IMMEDIATE")))
    end
    dm_run!(Juango.SchemaState(), op; backwards = true)
    # test_create_model_with_covering_unique_constraint (INCLUDE on PostgreSQL)
    cu = Juango.ConstraintSpec(:unique, "covering_pink_constraint"; columns = ["pink"], include = ["weight"])
    op = DM.CreateModel("tcmc2_pony"; columns = [dmcol("pink"), dmcol("weight", :float)], constraints = [cu])
    dm_run!(Juango.SchemaState(), op)
    dm_insert("tcmc2_pony", :pink => 1, :weight => 4.0)
    @test dm_fails(() -> dm_insert("tcmc2_pony", :pink => 1, :weight => 4.0))
    dm_run!(Juango.SchemaState(), op; backwards = true)
    # test_delete_model
    with_ponies("tdm") do st
        op = DM.DeleteModel("tdm_pony")
        st2 = dm_run!(st, op)
        @test !haskey(st2, "tdm_pony") && !("tdm_pony" in dm_tables())
        dm_run!(st, op; backwards = true)
        @test "tdm_pony" in dm_tables()
    end
    # test_rename_model (foreign keys pointing at it follow)
    with_ponies("trm"; rider = true) do st
        op = DM.RenameModel("trm_pony", "trm_horse")
        st2 = dm_run!(st, op)
        @test haskey(st2, "trm_horse") && !haskey(st2, "trm_pony") && st2["trm_rider"].columns[1].references == "trm_horse"
        @test "trm_horse" in dm_tables() && !("trm_pony" in dm_tables())
        @test dm_fk("trm_rider", "pony_id", "trm_horse")
        dm_run!(st, op; backwards = true)
        @test "trm_pony" in dm_tables() && dm_fk("trm_rider", "pony_id", "trm_pony")
    end
    # test_rename_model_with_self_referential_fk
    with_ponies("trms"; rider = true) do st
        op = DM.RenameModel("trms_rider", "trms_horserider")
        st2 = dm_run!(st, op)
        @test st2["trms_horserider"].columns[2].references == "trms_horserider"
        @test dm_fk("trms_horserider", "friend_id", "trms_horserider")
        dm_run!(st, op; backwards = true)
        @test dm_fk("trms_rider", "friend_id", "trms_rider")
    end
    # test_rename_model_no_relations_with_db_table_noop, test_alter_model_table_noop
    with_ponies("tamtn") do st
        op = DM.RenameModel("tamtn_pony", "tamtn_pony")
        @test isempty(DM.forwards(op, Juango.backend(), st, DM.state_forwards!(op, Juango.copy_state(st), "testapp"), String[]))
    end
    # test_add_field (existing rows get the default)
    with_ponies("taf") do st
        dm_insert("taf_pony", :pink => 1, :weight => 1.0)
        op = DM.AddField("taf_pony", dmcol("height", :float; default = 5.0))
        st2 = dm_run!(st, op)
        @test length(st2["taf_pony"].columns) == 3 && haskey(dm_cols("taf_pony"), "height")
        @test only(Juango.execute("SELECT height FROM taf_pony"))[:height] == 5.0
        dm_run!(st, op; backwards = true)
        @test !haskey(dm_cols("taf_pony"), "height")
    end
    # test_add_charfield, test_add_textfield
    with_ponies("tachf") do st
        dm_insert("tachf_pony", :pink => 1, :weight => 1.0)
        ops = [DM.AddField("tachf_pony", Juango.Column("text", :string; max_length = 10, default = "some text")),
               DM.AddField("tachf_pony", Juango.Column("empty", :string; max_length = 10, default = "")),
               DM.AddField("tachf_pony", Juango.Column("digits", :string; max_length = 10, default = "42")),
               DM.AddField("tachf_pony", Juango.Column("quotes", :text; default = "\"'\""))]
        dm_run!(st, ops...)
        r = only(Juango.execute("SELECT text, empty, digits, quotes FROM tachf_pony"))
        @test (r[:text], r[:empty], r[:digits], r[:quotes]) == ("some text", "", "42", "\"'\"")
        dm_run!(st, ops...; backwards = true)
        @test !haskey(dm_cols("tachf_pony"), "text")
    end
    # test_column_name_quoting
    with_ponies("tcnq") do st
        op = DM.AddField("tcnq_pony", dmcol("select"; default = 0))
        dm_run!(st, op)
        @test haskey(dm_cols("tcnq_pony"), "select")
        dm_run!(st, op; backwards = true)
        @test !haskey(dm_cols("tcnq_pony"), "select")
    end
    # test_remove_field
    with_ponies("trf") do st
        op = DM.RemoveField("trf_pony", "pink")
        st2 = dm_run!(st, op)
        @test [c.name for c in st2["trf_pony"].columns] == ["weight"] && !haskey(dm_cols("trf_pony"), "pink")
        dm_run!(st, op; backwards = true)
        @test haskey(dm_cols("trf_pony"), "pink")
    end
    # test_remove_fk
    with_ponies("trfk"; rider = true) do st
        op = DM.RemoveField("trfk_rider", "pony_id")
        dm_run!(st, op)
        @test !haskey(dm_cols("trfk_rider"), "pony_id")
        dm_run!(st, op; backwards = true)
        @test dm_fk("trfk_rider", "pony_id", "trfk_pony")
    end
    # test_alter_field
    with_ponies("talf") do st
        op = DM.AlterField("talf_pony", dmcol("pink"; null = true))
        st2 = dm_run!(st, op)
        @test st2["talf_pony"].columns[1].null && dm_cols("talf_pony")["pink"].null
        dm_run!(st, op; backwards = true)
        @test !dm_cols("talf_pony")["pink"].null
    end
    # test_alter_field_with_index
    with_ponies("tafwi") do st
        op = DM.AlterField("tafwi_pony", dmcol("pink"; index = true))
        dm_run!(st, op)
        @test dm_index("tafwi_pony", ["pink"])
        dm_run!(st, op; backwards = true)
        @test !dm_index("tafwi_pony", ["pink"])
    end
    # test_alter_fk, test_alter_fk_non_fk
    with_ponies("tafk"; rider = true) do st
        op = DM.AlterField("tafk_rider", dmcol("pony_id", :bigint))
        dm_run!(st, op)
        @test !dm_fk("tafk_rider", "pony_id", "tafk_pony")
        dm_run!(st, op; backwards = true)
        @test dm_fk("tafk_rider", "pony_id", "tafk_pony")
    end
    # test_alter_model_table_comment
    if Juango.backend() isa Union{Juango.PostgresBackend,Juango.MySQLBackend}
        with_ponies("tamtc") do st
            op = DM.AlterModelTableComment("tamtc_pony", "Custom pony comment")
            st2 = dm_run!(st, op)
            @test st2["tamtc_pony"].comment == "Custom pony comment"
            dm_run!(st, op; backwards = true)
        end
    end
    # test_alter_field_pk_fk, test_smallfield_autofield_foreignfield_growth: foreign keys follow the key's size
    with_ponies("tafpk"; rider = true) do st
        op = DM.AlterPrimaryKey("tafpk_pony", :smallauto)
        dm_run!(st, op)
        @test occursin("smallint", dm_cols("tafpk_pony")["id"].type) && occursin("smallint", dm_cols("tafpk_rider")["pony_id"].type) ||
              Juango.backend() isa Juango.SQLiteBackend
        @test dm_fk("tafpk_rider", "pony_id", "tafpk_pony")
        dm_run!(st, op; backwards = true)
        @test dm_fk("tafpk_rider", "pony_id", "tafpk_pony")
    end
    # test_rename_field
    with_ponies("trnf"; indexes = [Juango.Index("pink", "weight"; name = "trnf_pony_pink_weight")]) do st
        dm_insert("trnf_pony", :pink => 1, :weight => 1.0)
        op = DM.RenameField("trnf_pony", "pink", "blue")
        st2 = dm_run!(st, op)
        @test [c.name for c in st2["trnf_pony"].columns] == ["blue", "weight"]
        @test st2["trnf_pony"].indexes[1].columns == ["blue", "weight"]          # (the index follows)
        @test haskey(dm_cols("trnf_pony"), "blue") && !haskey(dm_cols("trnf_pony"), "pink")
        @test dm_cons("trnf_pony")["trnf_pony_pink_weight"].columns == ["blue", "weight"]
        @test only(Juango.execute("SELECT blue FROM trnf_pony"))[:blue] == 1
        dm_run!(st, op; backwards = true)
        @test haskey(dm_cols("trnf_pony"), "pink") && !haskey(dm_cols("trnf_pony"), "blue")
    end
    # test_rename_field_unique_together
    with_ponies("trfu"; unique_together = [["pink", "weight"]]) do st
        op = DM.RenameField("trfu_pony", "pink", "blue")
        st2 = dm_run!(st, op)
        @test st2["trfu_pony"].unique_together == [["blue", "weight"]]
        dm_insert("trfu_pony", :blue => 1, :weight => 1.0)
        @test dm_fails(() -> dm_insert("trfu_pony", :blue => 1, :weight => 1.0))
        dm_run!(st, op; backwards = true)
        @test dm_unique("trfu_pony", ["pink", "weight"])
    end
    # (a constraint's columns follow a renamed column in the state too)
    let st = dm_state("p" => [dmcol("pink")])
        DM.state_forwards!(DM.AddConstraint("p", Juango.ConstraintSpec(:unique, "p_pink_u"; columns = ["pink"])), st, "testapp")
        DM.state_forwards!(DM.RenameField("p", "pink", "blue"), st, "testapp")
        @test st["p"].constraints[1].columns == ["blue"]
    end
    # test_rename_missing_field
    @test_throws "table 'foo' has no column 'field'" DM.state_forwards!(DM.RenameField("foo", "field", "new_field"), dm_state("foo" => [dmcol("a")]), "testapp")
    # test_alter_unique_together, test_alter_unique_together_remove
    with_ponies("taut") do st
        op = DM.AlterUniqueTogether("taut_pony", [["pink", "weight"]])
        st2 = dm_run!(st, op)
        @test st2["taut_pony"].unique_together == [["pink", "weight"]] && dm_unique("taut_pony", ["pink", "weight"])
        dm_insert("taut_pony", :pink => 1, :weight => 1.0); dm_insert("taut_pony", :pink => 2, :weight => 1.0)
        @test dm_fails(() -> dm_insert("taut_pony", :pink => 1, :weight => 1.0))
        op2 = DM.AlterUniqueTogether("taut_pony", [])
        dm_run!(st2, op2)
        @test !dm_unique("taut_pony", ["pink", "weight"])
        dm_run!(st2, op2; backwards = true)
        @test dm_unique("taut_pony", ["pink", "weight"])
        dm_run!(st, op; backwards = true)
        @test !dm_unique("taut_pony", ["pink", "weight"])
    end
    # test_add_index, test_remove_index
    with_ponies("tadin") do st
        op = DM.AddIndex("tadin_pony", Juango.Index("pink"; name = "test_adin_pony_pink_idx"))
        @test DM.describe(op) isa String
        st2 = dm_run!(st, op)
        @test length(st2["tadin_pony"].indexes) == 1 && dm_named("tadin_pony", "test_adin_pony_pink_idx") && dm_index("tadin_pony", ["pink"])
        op2 = DM.RemoveIndex("tadin_pony", "test_adin_pony_pink_idx")
        st3 = dm_run!(st2, op2)
        @test isempty(st3["tadin_pony"].indexes) && !dm_named("tadin_pony", "test_adin_pony_pink_idx")
        dm_run!(st2, op2; backwards = true)
        @test dm_named("tadin_pony", "test_adin_pony_pink_idx")
        dm_run!(st, op; backwards = true)
        @test !dm_named("tadin_pony", "test_adin_pony_pink_idx")
    end
    # test_add_func_index, test_remove_func_index
    with_ponies("tafi"; columns = [Juango.Column("name", :string; max_length = 20), dmcol("pink"; default = 3)]) do st
        op = DM.AddIndex("tafi_pony", Juango.Index(Lower(F(:name)); name = "test_adfuncin_pony_lower_name"))
        dm_run!(st, op)
        @test dm_named("tafi_pony", "test_adfuncin_pony_lower_name") || dm_mysql()
        dm_run!(st, op; backwards = true)
        @test !dm_named("tafi_pony", "test_adfuncin_pony_lower_name")
    end
    # test_add_constraint, test_remove_constraint
    with_ponies("tadc") do st
        c = Juango.ConstraintSpec(:check, "test_add_constraint_pony_pink_gt_2"; condition = Q(pink__gt = 2))
        op = DM.AddConstraint("tadc_pony", c)
        st2 = dm_run!(st, op)
        @test length(st2["tadc_pony"].constraints) == 1 && dm_named("tadc_pony", "test_add_constraint_pony_pink_gt_2")
        dm_insert("tadc_pony", :pink => 3, :weight => 1.0)
        @test dm_fails(() -> dm_insert("tadc_pony", :pink => 1, :weight => 1.0))
        op2 = DM.RemoveConstraint("tadc_pony", "test_add_constraint_pony_pink_gt_2")
        dm_run!(st2, op2)
        dm_insert("tadc_pony", :pink => 1, :weight => 1.0)
        @test dm_count("tadc_pony") == 2
        Juango.execute("DELETE FROM tadc_pony WHERE pink = 1")
        dm_run!(st2, op2; backwards = true)
        @test dm_fails(() -> dm_insert("tadc_pony", :pink => 1, :weight => 1.0))
        dm_run!(st, op; backwards = true)
        dm_insert("tadc_pony", :pink => 1, :weight => 1.0)
        @test dm_count("tadc_pony") == 2
    end
    # test_add_or_constraint
    with_ponies("taoc") do st
        c = Juango.ConstraintSpec(:check, "test_add_or_constraint_pony_pink_gt_2_or_weight_lt_0";
                                  condition = Q(pink__gt = 2, weight__gt = 2) | Q(weight__lt = 0))
        dm_run!(st, DM.AddConstraint("taoc_pony", c))
        dm_insert("taoc_pony", :pink => 3, :weight => 3.0); dm_insert("taoc_pony", :pink => 1, :weight => -1.0)
        @test dm_fails(() -> dm_insert("taoc_pony", :pink => 1, :weight => 3.0))
        @test dm_fails(() -> dm_insert("taoc_pony", :pink => 3, :weight => 1.0))
    end
    # test_add_partial_unique_constraint, test_remove_partial_unique_constraint
    with_ponies("tapu") do st
        c = Juango.ConstraintSpec(:unique, "test_constraint_pony_pink_for_weight_gt_5_uniq"; columns = ["pink"], condition = Q(weight__gt = 5))
        op = DM.AddConstraint("tapu_pony", c)
        st2 = dm_run!(st, op)
        dm_insert("tapu_pony", :pink => 1, :weight => 4.0); dm_insert("tapu_pony", :pink => 1, :weight => 4.0); dm_insert("tapu_pony", :pink => 1, :weight => 6.0)
        @test dm_fails(() -> dm_insert("tapu_pony", :pink => 1, :weight => 7.0)) != dm_mysql()
        dm_run!(st2, DM.RemoveConstraint("tapu_pony", c.name))
        dm_insert("tapu_pony", :pink => 1, :weight => 7.0)
        @test dm_count("tapu_pony") == (dm_mysql() ? 5 : 4)        # (MySQL took the earlier row too)
    end
    # test_add_func_unique_constraint
    with_ponies("tafuc") do st
        c = Juango.ConstraintSpec(:unique, "test_adfuncuc_pony_abs_uq"; expressions = [("ABS", "weight")])
        op = DM.AddConstraint("tafuc_pony", c)
        dm_run!(st, op)
        dm_insert("tafuc_pony", :pink => 1, :weight => 4.0)
        @test dm_fails(() -> dm_insert("tafuc_pony", :pink => 1, :weight => -4.0)) != dm_mysql()
        dm_run!(st, op; backwards = true)
    end
    # test_run_sql
    op = DM.RunSQL(["CREATE TABLE i_love_ponies (id int, special_thing varchar(15))",
                    "INSERT INTO i_love_ponies (id, special_thing) VALUES (1, 'i love ponies')",
                    "INSERT INTO i_love_ponies (id, special_thing) VALUES (2, 'i love django')"],
                   "DROP TABLE i_love_ponies")
    st = dm_run!(Juango.SchemaState(), op)
    @test isempty(st) && dm_count("i_love_ponies") == 2
    dm_run!(Juango.SchemaState(), op; backwards = true)
    @test !("i_love_ponies" in dm_tables())
    # (one string of several statements, run one by one, as Django's)
    op = DM.RunSQL("""CREATE TABLE i_love_ponies (id int, special_thing varchar(15));
                      INSERT INTO i_love_ponies (id, special_thing) VALUES (1, 'i love; ponies');
                      -- a comment; with a semicolon
                      INSERT INTO i_love_ponies (id, special_thing) VALUES (2, 'i love django');""", "DROP TABLE i_love_ponies")
    @test length(op.forward) == 3
    dm_run!(Juango.SchemaState(), op)
    @test dm_count("i_love_ponies") == 2 && only(Juango.execute("SELECT special_thing FROM i_love_ponies WHERE id = 1"))[:special_thing] == "i love; ponies"
    @test DM.split_sql("CREATE FUNCTION f() RETURNS int AS \$\$ SELECT 1; \$\$ LANGUAGE sql; SELECT 'a''b;c'") ==
          ["CREATE FUNCTION f() RETURNS int AS \$\$ SELECT 1; \$\$ LANGUAGE sql", "SELECT 'a''b;c'"]
    # test_run_sql_params
    pop = DM.RunSQL(["INSERT INTO i_love_ponies (id, special_thing) VALUES (3, 'Django');",
                     ["INSERT INTO i_love_ponies (id, special_thing) VALUES (4, ?);", ["Ponies"]],
                     ("INSERT INTO i_love_ponies (id, special_thing) VALUES (?, ?);", (5, "Python"))],
                    ["DELETE FROM i_love_ponies WHERE special_thing = 'Django';",
                     ["DELETE FROM i_love_ponies WHERE special_thing = 'Ponies';", nothing],
                     ("DELETE FROM i_love_ponies WHERE id = ? OR special_thing = ?;", [5, "Python"])])
    dm_run!(Juango.SchemaState(), pop)
    @test dm_count("i_love_ponies") == 5
    dm_run!(Juango.SchemaState(), pop; backwards = true)
    @test dm_count("i_love_ponies") == 2
    @test occursin("(\"INSERT INTO i_love_ponies (id, special_thing) VALUES (4, ?);\", Any[\"Ponies\"])", DM.op_code(pop))
    # test_run_sql_params_invalid
    @test_throws "Expected a 2-tuple but got 1" DM.RunSQL([["INSERT INTO foo (bar) VALUES ('buz');"]])
    @test_throws "Expected a 2-tuple but got 3" DM.RunSQL([("INSERT INTO foo (bar) VALUES ('buz');", [], [])])
    dm_run!(Juango.SchemaState(), op; backwards = true)
    @test !("i_love_ponies" in dm_tables())
    # test_run_sql_noop
    @test isempty(dm_run!(Juango.SchemaState(), DM.RunSQL("", "")))
    # test_run_sql_backward_reverse_sql_required
    @test_throws DM.IrreversibleError dm_run!(Juango.SchemaState(), DM.RunSQL("SELECT 1"); backwards = true)
    # test_run_python (with the models as they were: a RunJulia function of one argument)
    with_ponies("trp") do st
        n = Ref(0)
        op = DM.RunJulia(() -> (dm_insert("trp_pony", :pink => 1, :weight => 3.55); dm_insert("trp_pony", :pink => 1, :weight => 5.0)),
                         () -> Juango.execute("DELETE FROM trp_pony"))
        dm_run!(st, op)
        @test dm_count("trp_pony") == 2
        dm_run!(st, op; backwards = true)
        @test dm_count("trp_pony") == 0
        @test_throws DM.IrreversibleError dm_run!(st, DM.RunJulia(() -> nothing); backwards = true)
    end
    # test_separate_database_and_state
    with_ponies("tsdas") do st
        op = DM.SeparateDatabaseAndState(; state_operations = [DM.DeleteModel("tsdas_pony")],
                                           database_operations = [DM.RunSQL("CREATE TABLE tsdas_somethingelse (id int)", "DROP TABLE tsdas_somethingelse")])
        st2 = dm_run!(st, op)
        @test !haskey(st2, "tsdas_pony") && "tsdas_pony" in dm_tables() && "tsdas_somethingelse" in dm_tables()
        dm_run!(st, op; backwards = true)
        @test !("tsdas_somethingelse" in dm_tables())
    end
    # test_composite_pk_operations
    op = DM.CreateModel("tcpk_release"; columns = [dmcol("version"), dmcol("name")], pk = :composite, pk_columns = ["version", "name"])
    dm_run!(Juango.SchemaState(), op)
    @test any(v -> v.primary_key && sort(v.columns) == ["name", "version"], values(dm_cons("tcpk_release")))
    dm_run!(Juango.SchemaState(), op; backwards = true)
    @test !("tcpk_release" in dm_tables())
    # not translated: test_create_model_with_duplicate_base, _manager_name, test_create_proxy_model,
    # test_create_unmanaged_model, test_create_model_managers, test_delete_proxy_model,
    # test_alter_model_options*, test_alter_model_managers*, test_alter_order_with_respect_to (no
    # bases, proxies, managers, options or order_with_respect_to in migrations); the m2m rename tests
    # (join tables are ordinary tables, renamed with RenameModel); test_add_field_preserve_default;
    # test_rename_index* (#257); test_alter_constraint (violation messages aren't in migrations);
    # test_references_* (no references_model API); the *_ignore_swapped tests (in migrations.jl);
    # the generated-field and db_default tests (in migrations.jl)
end

# --- test_autodetector: the operations between two states --------------------------------------------

dmst(ops...; app = "testapp") = (st = Juango.SchemaState(); foreach(op -> DM.state_forwards!(op, st, app), ops); st)
dmchanges(from, to; app = "testapp", rename = false) = dmcode(DM.diff_states(from, to, app; questioner = _ -> rename))
author(cols...; kw...) = DM.CreateModel("author"; model = "Author", columns = collect(Juango.Column, cols), kw...)
book(cols...; kw...) = DM.CreateModel("book"; model = "Book", columns = collect(Juango.Column, cols), kw...)
aname = Juango.Column("name", :string; max_length = 200)
bauthor = dmcol("author_id", :fk; references = "author")
btitle = Juango.Column("title", :string; max_length = 200)

# test_multidb's routers
struct DmAgnosticRouter end
Juango.allow_migrate(::DmAgnosticRouter, db, app; model = nothing, kw...) = nothing
struct DmMigrateNothingRouter end
Juango.allow_migrate(::DmMigrateNothingRouter, db, app; model = nothing, kw...) = false
struct DmMigrateEverythingRouter end
Juango.allow_migrate(::DmMigrateEverythingRouter, db, app; model = nothing, kw...) = true
struct DmMigrateWhenFooRouter end
Juango.allow_migrate(::DmMigrateWhenFooRouter, db, app; model = nothing, kw...) = get(kw, :foo, false)

@testset "django migrations: test_multidb (MultiDBOperationTests: the routers' allow_migrate per operation, #300)" begin
    function create_model(app, should_run, routers)
        t = "$(app)_pony"
        op = DM.CreateModel(t; columns = [dmcol("pink"; default = 3)])
        override_settings(DATABASE_ROUTERS = Any[routers...]) do
            @test !(t in dm_tables())
            st = dm_run!(Juango.SchemaState(), op; app = app)
            @test (t in dm_tables()) == should_run
            dm_run!(st, op; app = app, backwards = true)
            @test !(t in dm_tables())
        end
    end
    create_model("test_mltdb_crmo", true, [DmAgnosticRouter()])                       # test_create_model
    create_model("test_mltdb_crmo2", false, [DmMigrateNothingRouter()])               # test_create_model2
    create_model("test_mltdb_crmo3", true, [DmMigrateEverythingRouter()])             # test_create_model3
    create_model("test_mltdb_crmo4", true, [DmAgnosticRouter(), DmAgnosticRouter()])  # test_create_model4
    create_model("test_mltdb_crmo4", false, [DmMigrateNothingRouter(), DmMigrateEverythingRouter()])
    create_model("test_mltdb_crmo4", true, [DmMigrateEverythingRouter(), DmMigrateNothingRouter()])
    # test_run_sql_* and test_run_python_* (RunJulia): run only when the router allows, by the operation's hints
    for (app, should_run, routers, hints) in (("test_mltdb_runsql", false, [DmMigrateNothingRouter()], (;)),
                                              ("test_mltdb_runsql2", false, [DmMigrateWhenFooRouter()], (;)),
                                              ("test_mltdb_runsql3", true, [DmMigrateWhenFooRouter()], (foo = true,)))
        for julia in (false, true)
            p = julia ? replace(app, "runsql" => "runpython") : app
            with_ponies(p) do st
                t = Juango.quote_name(Juango.backend(), "$(p)_pony")
                op = julia ? DM.RunJulia(() -> (dm_insert("$(p)_pony", :pink => 1, :weight => 3.55); dm_insert("$(p)_pony", :weight => 5.0)); hints = hints) :
                             DM.RunSQL("INSERT INTO $t (pink, weight) VALUES (1, 3.55);\nINSERT INTO $t (pink, weight) VALUES (3, 5.0);"; hints = hints)
                c = Juango.copy_state(st)
                @test DM.state_forwards!(op, c, p) === c && keys(c) == keys(st)            # (the state is unchanged)
                @test dm_count("$(p)_pony") == 0
                override_settings(DATABASE_ROUTERS = Any[routers...]) do
                    dm_run!(st, op; app = p)
                end
                @test dm_count("$(p)_pony") == (should_run ? 2 : 0)
            end
        end
    end
end

@testset "django migrations: test_autodetector" begin
    # test_new_model
    @test dmchanges(dmst(), dmst(author(aname))) == dmcode([author(aname)])
    # test_old_model
    @test dmchanges(dmst(author(aname)), dmst()) == dmcode([DM.DeleteModel("author")])
    # test_add_field
    @test dmchanges(dmst(author(aname)), dmst(author(aname, dmcol("age")))) == dmcode([DM.AddField("author", dmcol("age"))])
    # test_remove_field
    @test dmchanges(dmst(author(aname)), dmst(author())) == dmcode([DM.RemoveField("author", "name")])
    # test_alter_field
    @test dmchanges(dmst(author(aname)), dmst(author(Juango.Column("name", :string; max_length = 400)))) ==
          dmcode([DM.AlterField("author", Juango.Column("name", :string; max_length = 400))])
    # test_alter_field_to_not_null_with_default
    @test dmchanges(dmst(author(Juango.Column("name", :string; max_length = 200, null = true))),
                    dmst(author(Juango.Column("name", :string; max_length = 200, default = "Ada Lovelace")))) ==
          dmcode([DM.AlterField("author", Juango.Column("name", :string; max_length = 200, default = "Ada Lovelace"))])
    # test_add_field_with_default
    @test dmchanges(dmst(author()), dmst(author(Juango.Column("name", :string; max_length = 200, default = "Ada Lovelace")))) ==
          dmcode([DM.AddField("author", Juango.Column("name", :string; max_length = 200, default = "Ada Lovelace"))])
    # test_rename_field (asked; Juango adds the new column before removing the old one, Django the other way round)
    @test dmchanges(dmst(author(aname)), dmst(author(Juango.Column("names", :string; max_length = 200))); rename = true) ==
          dmcode([DM.RenameField("author", "name", "names")])
    @test dmchanges(dmst(author(aname)), dmst(author(Juango.Column("names", :string; max_length = 200)))) ==
          dmcode([DM.AddField("author", Juango.Column("names", :string; max_length = 200)), DM.RemoveField("author", "name")])
    # test_rename_model (asked; the foreign keys pointing at it follow, so they don't change)
    writer = DM.CreateModel("writer"; model = "Writer", columns = [aname])
    @test dmchanges(dmst(author(aname), book(bauthor)), dmst(writer, book(dmcol("author_id", :fk; references = "writer"))); rename = true) ==
          dmcode([DM.RenameModel("author", "writer"; model = "Writer")])
    # test_rename_field_with_renamed_model (both asked: the table's columns are compared without their names)
    @test dmchanges(dmst(author(aname)), dmst(DM.CreateModel("writer"; model = "Writer", columns = [Juango.Column("renamed_name", :string; max_length = 200)]));
                    rename = true) == dmcode([DM.RenameModel("author", "writer"; model = "Writer"), DM.RenameField("writer", "name", "renamed_name")])
    # test_circular_fk_dependency, test_same_app_circular_fk_dependency (a migration's foreign keys are added once its tables exist)
    @test dmchanges(dmst(), dmst(author(aname, dmcol("book_id", :fk; references = "book")), book(btitle, bauthor))) ==
          dmcode([book(btitle, bauthor), author(aname, dmcol("book_id", :fk; references = "book"))])
    # test_alter_db_table_add, test_alter_db_table_change (the model's table changed: renamed without asking)
    @test dmchanges(dmst(author(aname)), dmst(DM.CreateModel("author_one"; model = "Author", columns = [aname]))) ==
          dmcode([DM.RenameModel("author", "author_one"; model = "Author")])
    # test_alter_db_table_no_changes
    @test isempty(dmchanges(dmst(author(aname)), dmst(author(aname))))
    # test_alter_db_table_comment_add, _change, _remove, _no_changes
    @test dmchanges(dmst(author(aname)), dmst(author(aname; comment = "Table comment"))) == dmcode([DM.AlterModelTableComment("author", "Table comment")])
    @test dmchanges(dmst(author(aname; comment = "Table comment")), dmst(author(aname; comment = "New table comment"))) ==
          dmcode([DM.AlterModelTableComment("author", "New table comment")])
    @test dmchanges(dmst(author(aname; comment = "Table comment")), dmst(author(aname))) == dmcode([DM.AlterModelTableComment("author", nothing)])
    @test isempty(dmchanges(dmst(author(aname; comment = "Table comment")), dmst(author(aname; comment = "Table comment"))))
    # test_empty_unique_together
    @test isempty(dmchanges(dmst(author(aname; unique_together = [])), dmst(author(aname; unique_together = []))))
    # test_create_model_with_indexes
    ix = Juango.Index("name"; name = "create_model_with_indexes_idx")
    @test dmchanges(dmst(), dmst(author(aname; indexes = [ix]))) == dmcode([author(aname; indexes = [ix])])
    # test_add_indexes, test_remove_indexes
    bix = Juango.Index("author_id", "title"; name = "book_title_author_idx")
    @test dmchanges(dmst(author(aname), book(bauthor, btitle)), dmst(author(aname), book(bauthor, btitle; indexes = [bix]))) == dmcode([DM.AddIndex("book", bix)])
    @test dmchanges(dmst(author(aname), book(bauthor, btitle; indexes = [bix])), dmst(author(aname), book(bauthor, btitle))) ==
          dmcode([DM.RemoveIndex("book", "book_title_author_idx")])
    # test_rename_indexes (#257: Juango drops and recreates it)
    @test_broken dmchanges(dmst(book(bauthor, btitle; indexes = [bix])), dmst(book(bauthor, btitle; indexes = [Juango.Index("author_id", "title"; name = "renamed_idx")]))) ==
                 ["RenameIndex(\"book\", \"renamed_idx\", \"book_title_author_idx\")"]
    # test_order_fields_indexes (the field before its index; removed, the index before the field)
    @test dmchanges(dmst(author(aname), book(bauthor)), dmst(author(aname), book(bauthor, btitle; indexes = [bix]))) ==
          dmcode([DM.AddField("book", btitle), DM.AddIndex("book", bix)])
    @test dmchanges(dmst(author(aname), book(bauthor, btitle; indexes = [bix])), dmst(author(aname), book(bauthor))) ==
          dmcode([DM.RemoveIndex("book", "book_title_author_idx"), DM.RemoveField("book", "title")])
    # test_create_model_with_check_constraint, test_add_constraints, test_remove_constraints
    chk = Juango.ConstraintSpec(:check, "name_contains_bob"; condition = Q(name__contains = "Bob"))
    @test dmchanges(dmst(), dmst(author(aname; constraints = [chk]))) == dmcode([author(aname; constraints = [chk])])
    @test dmchanges(dmst(author(aname)), dmst(author(aname; constraints = [chk]))) == dmcode([DM.AddConstraint("author", chk)])
    @test dmchanges(dmst(author(aname; constraints = [chk])), dmst(author(aname))) == dmcode([DM.RemoveConstraint("author", "name_contains_bob")])
    # test_constraint_dropped_and_recreated
    chk2 = Juango.ConstraintSpec(:check, "name_contains_bob"; condition = Q(name__contains = "Robert"))
    @test dmchanges(dmst(author(aname; constraints = [chk])), dmst(author(aname; constraints = [chk2]))) ==
          dmcode([DM.RemoveConstraint("author", "name_contains_bob"), DM.AddConstraint("author", chk2)])
    # test_add_unique_together, test_remove_unique_together, test_unique_together_no_changes
    @test dmchanges(dmst(author(aname), book(bauthor, btitle)), dmst(author(aname), book(bauthor, btitle; unique_together = [["author_id", "title"]]))) ==
          dmcode([DM.AlterUniqueTogether("book", [["author_id", "title"]])])
    @test dmchanges(dmst(author(aname), book(bauthor, btitle; unique_together = [["author_id", "title"]])), dmst(author(aname), book(bauthor, btitle))) ==
          dmcode([DM.AlterUniqueTogether("book", [])])
    @test isempty(dmchanges(dmst(book(bauthor, btitle; unique_together = [["author_id", "title"]])), dmst(book(bauthor, btitle; unique_together = [["author_id", "title"]]))))
    # test_unique_together_ordering (the columns' order matters: it's the index's)
    @test dmchanges(dmst(book(bauthor, btitle; unique_together = [["author_id", "title"]])), dmst(book(bauthor, btitle; unique_together = [["title", "author_id"]]))) ==
          dmcode([DM.AlterUniqueTogether("book", [["title", "author_id"]])])
    # test_add_field_and_unique_together
    @test dmchanges(dmst(author(aname), book(bauthor, btitle)), dmst(author(aname), book(bauthor, btitle, dmcol("newfield"); unique_together = [["title", "newfield"]]))) ==
          dmcode([DM.AddField("book", dmcol("newfield")), DM.AlterUniqueTogether("book", [["title", "newfield"]])])
    # test_remove_field_and_unique_together
    @test dmchanges(dmst(author(aname), book(bauthor, btitle, dmcol("newfield"); unique_together = [["title", "newfield"]])), dmst(author(aname), book(bauthor, btitle))) ==
          dmcode([DM.AlterUniqueTogether("book", []), DM.RemoveField("book", "newfield")])
    # test_partly_alter_unique_together_increase, _decrease
    @test dmchanges(dmst(author(aname, dmcol("age"); unique_together = [["name"]])), dmst(author(aname, dmcol("age"); unique_together = [["name"], ["age"]]))) ==
          dmcode([DM.AlterUniqueTogether("author", [["name"], ["age"]])])
    @test dmchanges(dmst(author(aname, dmcol("age"); unique_together = [["name"], ["age"]])), dmst(author(aname, dmcol("age"); unique_together = [["name"]]))) ==
          dmcode([DM.AlterUniqueTogether("author", [["name"]])])
    # test_rename_field_and_unique_together (the rename first)
    @test dmchanges(dmst(book(bauthor, btitle, dmcol("newfield"); unique_together = [["title", "newfield"]])),
                    dmst(book(bauthor, btitle, dmcol("newfield2"); unique_together = [["title", "newfield2"]])); rename = true) ==
          dmcode([DM.RenameField("book", "newfield", "newfield2")])
    @test dmchanges(dmst(book(bauthor, btitle, dmcol("newfield"); unique_together = [["author_id", "newfield"]])),
                    dmst(book(bauthor, btitle, dmcol("newfield2"); unique_together = [["title", "newfield2"]])); rename = true) ==
          dmcode([DM.RenameField("book", "newfield", "newfield2"), DM.AlterUniqueTogether("book", [["title", "newfield2"]])])
    # test_replace_string_with_foreignkey
    @test dmchanges(dmst(author(aname), book(Juango.Column("author", :string; max_length = 200))), dmst(author(aname), book(bauthor))) ==
          dmcode([DM.AddField("book", bauthor), DM.RemoveField("book", "author")])
    # test_foreign_key_removed_before_target_model
    @test dmchanges(dmst(author(aname), book(bauthor, btitle)), dmst(book(btitle))) ==
          dmcode([DM.RemoveField("book", "author_id"), DM.DeleteModel("author")])
    # test_non_circular_foreignkey_dependency_removal (the table pointing at the other goes first)
    @test dmchanges(dmst(author(aname), book(bauthor)), dmst()) == dmcode([DM.DeleteModel("book"), DM.DeleteModel("author")])
    # test_alter_fk_before_model_deletion
    @test dmchanges(dmst(author(aname), DM.CreateModel("aardvark"; columns = [aname]), book(bauthor)),
                    dmst(DM.CreateModel("aardvark"; columns = [aname]), book(dmcol("author_id", :fk; references = "aardvark")))) ==
          dmcode([DM.AlterField("book", dmcol("author_id", :fk; references = "aardvark")), DM.DeleteModel("author")])
    # test_mti_inheritance_model_removal
    @test dmchanges(dmst(author(aname), DM.CreateModel("aardvark"; columns = [aname], parent = "author")), dmst(author(aname))) ==
          dmcode([DM.DeleteModel("aardvark")])
    # test_add_composite_pk, test_remove_composite_pk (#259: changing a table's primary key isn't supported)
    @test_broken (try dmchanges(dmst(author(aname)), dmst(author(aname; pk = :composite, pk_columns = ["name"]))); true catch; false end)
    # test_parse_number
    for (name, n) in [("no_number", nothing), ("0001_initial", 1), ("0002_model3", 2), ("0002_auto_20380101_1112", 2), ("0002_squashed_0003", 3),
                      ("0002_model2_squashed_0003_other4", 3), ("0002_squashed_0003_squashed_0004", 4),
                      ("0002_model2_squashed_0003_other4_squashed_0005_other6", 5), ("0002_custom_name_20380101_1112_squashed_0003_model", 3),
                      ("2_squashed_4", 4)]
        @test DM.parse_number(name) == n
    end
    # not translated: the swappable, proxy, unmanaged, managers, options, order_with_respect_to,
    # many-to-many and through-model tests (Juango's migrations have none of these: a join table is a
    # table); the deconstruct tests (columns are plain values); the db_column and to_field rename
    # tests; generated-field ordering (in migrations.jl); the dependency tests between apps
    # (makemigrations' dependencies are tested in migrations.jl); test_arrange_for_graph, test_trim_apps,
    # test_custom_migration_name (makemigrations' naming and numbering are in migrations.jl)
end

@testset "django migrations: test_autodetector (MigrationSuggestNameTests)" begin
    # test_no_operations, test_no_operations_initial
    @test startswith(DM.suggest_name([], false), "auto_") && DM.suggest_name([], true) == "initial"
    # test_single_operation
    @test DM.suggest_name([DM.CreateModel("person"; model = "Person")], false) == "person"
    @test DM.suggest_name([DM.DeleteModel("person")], false) == "delete_person"
    # test_single_operation_long_name
    @test DM.suggest_name([DM.CreateModel("a"; model = "A"^53)], false) == "a"^53
    # test_two_operations
    @test DM.suggest_name([DM.CreateModel("person"; model = "Person"), DM.DeleteModel("animal")], false) == "person_delete_animal"
    # test_two_create_models, test_two_create_models_with_initial_true
    two = [DM.CreateModel("person"; model = "Person"), DM.CreateModel("animal"; model = "Animal")]
    @test DM.suggest_name(two, false) == "person_animal" && DM.suggest_name(two, true) == "initial"
    # test_many_operations_suffix
    @test DM.suggest_name([DM.CreateModel("p1"; model = "Person1"), DM.CreateModel("p2"; model = "Person2"), DM.CreateModel("p3"; model = "Person3"),
                           DM.DeleteModel("person4"), DM.DeleteModel("person5")], false) == "person1_person2_person3_delete_person4_and_more"
    # test_operation_with_no_suggested_name, test_none_name, test_none_name_with_initial_true
    @test startswith(DM.suggest_name([DM.CreateModel("person"; model = "Person"), DM.RunSQL("SELECT 1 FROM person;")], false), "auto_")
    @test startswith(DM.suggest_name([DM.RunSQL("SELECT 1 FROM person;")], false), "auto_")
    @test DM.suggest_name([DM.RunSQL("SELECT 1 FROM person;")], true) == "initial"
    # test_operation_with_invalid_chars_in_suggested_name
    @test DM.suggest_name([DM.AddConstraint("person", Juango.ConstraintSpec(:unique, "person.name-*~unique!"; columns = ["name"]))], false) ==
          "person_person_name_unique_"
    # (each operation's fragment, as Django's)
    @test DM.suggest_name([DM.AddField("person", dmcol("age"))], false) == "person_age"
    @test DM.suggest_name([DM.RenameField("person", "name", "title")], false) == "rename_name_person_title"
end

# --- test_graph -----------------------------------------------------------------------------------

"A migration graph from `node => [dependencies...]` pairs (nodes as \"app.name\")."
function dmgraph(deps::Pair...)
    k(s) = Tuple{String,String}(Tuple(split(s, '.')))
    nodes = Dict{Tuple{String,String},DM.Migration}()
    for (n, ds) in deps
        m = DM.Migration(; dependencies = [k(d) for d in ds])
        m.app, m.name = k(n)
        nodes[k(n)] = m
    end
    DM.Graph(nodes)
end
dmk(s) = Tuple{String,String}(Tuple(split(s, '.')))
# Django's forwards_plan / backwards_plan (Juango breaks ties by app and name, Django by depth-first order)
forwards_plan(g, n) = DM.topo_order(g, DM.ancestors(g, dmk(n)))
backwards_plan(g, n) = reverse(DM.topo_order(g, union(DM.descendants(g, dmk(n)), [dmk(n)])))
"Every migration comes after the ones it depends on."
valid_plan(g, plan) = all(i -> all(d -> !(d in plan) || findfirst(==(d), plan) < i, g.nodes[plan[i]].dependencies), eachindex(plan))

@testset "django migrations: test_graph" begin
    # test_simple_graph
    g = dmgraph("app_a.0001" => [], "app_a.0002" => ["app_a.0001"], "app_a.0003" => ["app_a.0002", "app_b.0002"],
                "app_a.0004" => ["app_a.0003"], "app_b.0001" => [], "app_b.0002" => ["app_b.0001"])
    @test forwards_plan(g, "app_a.0001") == [dmk("app_a.0001")]
    @test forwards_plan(g, "app_b.0002") == dmk.(["app_b.0001", "app_b.0002"])
    whole = forwards_plan(g, "app_a.0004")
    @test length(whole) == 6 && valid_plan(g, whole)
    @test backwards_plan(g, "app_b.0002") == dmk.(["app_a.0004", "app_a.0003", "app_b.0002"])
    @test [k for k in keys(g.nodes) if isempty(g.nodes[k].dependencies)] |> sort == dmk.(["app_a.0001", "app_b.0001"])   # root nodes
    @test DM.leaf_nodes(g, "app_a") == [dmk("app_a.0004")] && DM.leaf_nodes(g, "app_b") == [dmk("app_b.0002")]
    # test_complex_graph
    g = dmgraph("app_a.0001" => [], "app_a.0002" => ["app_a.0001"], "app_a.0003" => ["app_a.0002", "app_b.0002"],
                "app_a.0004" => ["app_a.0003", "app_c.0002"], "app_b.0001" => [], "app_b.0002" => ["app_b.0001"],
                "app_c.0001" => ["app_b.0001"], "app_c.0002" => ["app_c.0001", "app_a.0002"])
    p = forwards_plan(g, "app_c.0002")
    @test Set(p) == Set(dmk.(["app_b.0001", "app_c.0001", "app_a.0001", "app_a.0002", "app_c.0002"])) && valid_plan(g, p)
    p = forwards_plan(g, "app_a.0004")
    @test length(p) == 8 && valid_plan(g, p)
    @test Set(backwards_plan(g, "app_b.0001")) == Set(dmk.(["app_a.0004", "app_c.0002", "app_c.0001", "app_a.0003", "app_b.0002", "app_b.0001"]))
    @test backwards_plan(g, "app_b.0001")[end] == dmk("app_b.0001") && backwards_plan(g, "app_b.0001")[1] == dmk("app_a.0004")
    # test_circular_graph, test_circular_graph_2
    g = dmgraph("app_a.0001" => ["app_b.0002"], "app_a.0002" => ["app_a.0001"], "app_a.0003" => ["app_a.0002"],
                "app_b.0001" => ["app_a.0003"], "app_b.0002" => ["app_b.0001"])
    @test_throws "circular dependency between migrations: app_a.0001, app_a.0002, app_a.0003, app_b.0001, app_b.0002" DM.topo_order(g)
    g = dmgraph("A.0001" => ["C.0001"], "B.0001" => ["A.0001"], "C.0001" => ["B.0001"])
    @test_throws DM.MigrationError DM.topo_order(g)
    # test_iterative_dfs, test_iterative_dfs_complexity (a long chain: no recursion limit, and quick)
    n = 1000
    g = dmgraph(["app_a.$(lpad(i, 4, '0'))" => (i == 1 ? String[] : ["app_a.$(lpad(i - 1, 4, '0'))"]) for i in 1:n]...)
    @test forwards_plan(g, "app_a.$(lpad(n, 4, '0'))") == [dmk("app_a.$(lpad(i, 4, '0'))") for i in 1:n]
    @test backwards_plan(g, "app_a.0001") == [dmk("app_a.$(lpad(i, 4, '0'))") for i in n:-1:1]
    @test (@elapsed DM.topo_order(g)) < 5
    # test_plan_invalid_node
    @test_throws KeyError forwards_plan(dmgraph("app_a.0001" => []), "app_b.0001")
    # not translated: test_missing_parent_nodes, test_missing_child_nodes, test_validate_consistency_*
    # (build_graph checks every dependency exists: "... depends on ..., which does not exist", in
    # migrations.jl); test_remove_replaced_nodes, test_remove_replacement_node (squashing, in
    # migrations.jl); test_stringify, test_dummynode_* (Python internals)
end

# --- test_writer: operations and values written to a migration file and loaded back ---------------

"Write a migration with these operations to a file and load it back (Django's serialize round trip)."
function dm_roundtrip(ops...)
    dir = mktempdir()
    path = joinpath(dir, "0001_test.jl")
    write(path, DM.migration_code(DM.Migration(; operations = collect(DM.Operation, ops))))
    DM.load_migration(path, "testapp")
end
dm_default_back(v; kind = :string) = only(dm_roundtrip(DM.AddField("t", Juango.Column("c", kind; default = v))).operations).column.default

@testset "django migrations: test_writer" begin
    # test_serialize_numbers, test_serialize_constants, test_serialize_strings, test_serialize_multiline_strings
    for v in Any[1, -1, 0, 1.5, -2.25, 1e300, typemax(Int64), true, false, "foobar", "", "Ω unicode ✓", "multi\nline\tstring",
                 "a\"b'c\\d", "\$interpolation \$(x)", :symbol]
        @test isequal(dm_default_back(v), v)
    end
    # test_serialize_infinity, test_serialize_nan
    @test dm_default_back(Inf) == Inf && dm_default_back(-Inf) == -Inf && isnan(dm_default_back(NaN))
    # test_serialize_builtin_types (lists and dicts)
    @test dm_default_back(Any[1, "a", 2.5]) == Any[1, "a", 2.5]
    @test dm_default_back(Dict("a" => 1, "b" => [2, 3])) == Dict("a" => 1, "b" => [2, 3])
    # test_serialize_datetime, test_serialize_date, test_serialize_time, test_serialize_timedelta
    @test dm_default_back(Date(2014, 3, 31); kind = :date) == Date(2014, 3, 31)
    @test dm_default_back(DateTime(2014, 1, 1, 1, 1); kind = :datetime) == DateTime(2014, 1, 1, 1, 1)
    @test dm_default_back(Dates.Time(10, 30); kind = :time) == Dates.Time(10, 30)
    @test dm_default_back(Dates.Second(3600); kind = :duration) == Dates.Second(3600)
    @test dm_default_back(Dates.CompoundPeriod(Dates.Day(1), Dates.Hour(2)); kind = :duration) == Dates.CompoundPeriod(Dates.Day(1), Dates.Hour(2))
    # (an aware datetime)
    zdt = Juango.TimeZones.ZonedDateTime(DateTime(2012, 1, 1, 1, 1), Juango.TimeZones.tz"UTC")
    @test dm_default_back(zdt; kind = :datetime) == zdt
    # test_serialize_decimal
    @test dm_default_back(Juango.Decimal("1.3"); kind = :decimal) == Juango.Decimal("1.3")
    # test_serialize_uuid
    u = Juango.UUIDs.UUID("5c859437-d061-4847-b3f7-e6b78852f8c8")
    @test dm_default_back(u; kind = :uuid) == u
    # test_serialize_bytes (binary data)
    @test dm_default_back(UInt8[0x00, 0xff, 0x41]; kind = :binary) == UInt8[0x00, 0xff, 0x41]
    # every operation, written and read back, writes the same code (test_simple_migration and the operations)
    ops = DM.Operation[DM.CreateModel("w_author"; model = "Author", columns = [Juango.Column("name", :string; max_length = 200, comment = "x"),
                                                                             dmcol("score", :decimal; max_digits = 5, decimal_places = 2),
                                                                             dmcol("tags", :array; of = :string, null = true)],
                                      unique_together = [["name", "score"]], indexes = [Juango.Index("name"; name = "w_author_name")],
                                      constraints = [Juango.ConstraintSpec(:check, "w_author_score"; condition = Q(score__gte = 0) | Q(name = "x"))],
                                      comment = "Authors"),
                       DM.CreateModel("w_book"; columns = [dmcol("author_id", :fk; references = "w_author", index = true)]),
                       DM.AddField("w_book", Juango.Column("title", :string; max_length = 100, default = "Untitled")),
                       DM.AlterField("w_book", Juango.Column("title", :string; max_length = 150, null = true)),
                       DM.RenameField("w_book", "title", "name"), DM.RemoveField("w_book", "name"),
                       DM.AlterUniqueTogether("w_author", []), DM.AlterModelTableComment("w_author", nothing),
                       DM.AddIndex("w_book", Juango.Index(Lower(F(:author_id)); name = "w_book_lower")), DM.RemoveIndex("w_book", "w_book_lower"),
                       DM.AddConstraint("w_book", Juango.ConstraintSpec(:unique, "w_book_u"; columns = ["author_id"], condition = Q(author_id__gt = 1))),
                       DM.RemoveConstraint("w_book", "w_book_u"), DM.AlterPrimaryKey("w_book", :smallauto),
                       DM.RenameModel("w_book", "w_volume"; model = "Volume"), DM.DeleteModel("w_volume"),
                       DM.RunSQL(["SELECT 1", ("SELECT ?", Any[2])], "SELECT 3"), DM.CreateExtension("hstore"),
                       DM.SeparateDatabaseAndState(; state_operations = [DM.DeleteModel("w_author")])]
    m = dm_roundtrip(ops...)
    @test DM.op_code.(m.operations) == DM.op_code.(ops)
    # test_migration_file_header_comments / test_sorted_dependencies
    code = DM.migration_code(DM.Migration(; dependencies = [("b", "0002_x"), ("a", "0001_initial")], operations = []))
    @test startswith(code, "# Generated by Juango") && occursin("dependencies = [(\"b\", \"0002_x\"), (\"a\", \"0001_initial\")]", code)
    # test_models_import_omitted / test_custom_operation: not applicable (no imports to manage: every
    # operation and value type is in scope in a migration file)
end

# --- test_commands: migrate, showmigrations, sqlmigrate on an app's migration files -----------------

@testset "django migrations: test_commands" begin
    dir = mktempdir()
    old = Juango.settings.MIGRATION_MODULES
    configure!(MIGRATION_MODULES = merge(old, Dict("dmcmd" => dir)))
    quiet(f) = redirect_stdout(f, devnull)
    wm(name, code) = write(joinpath(dir, name * ".jl"), "using Juango.Migrations\n" * code)
    wm("0001_initial", """Migration(initial = true, operations = [CreateModel("dmcmd_author"; columns = [Column("name", :string; max_length = 255)])])""")
    wm("0002_second", """Migration(dependencies = [("dmcmd", "0001_initial")], operations = [
        AddField("dmcmd_author", Column("rating", :int; default = 0)),
        CreateModel("dmcmd_book"; columns = [Column("author_id", :fk; references = "dmcmd_author")])])""")
    try
        # test_showmigrations_list
        @test sprint(io -> DM.showmigrations("dmcmd"; io = io)) == "dmcmd\n [ ] 0001_initial\n [ ] 0002_second\n"
        # test_showmigrations_plan
        @test sprint(io -> DM.showmigrations("dmcmd"; plan = true, io = io)) == "[ ]  dmcmd.0001_initial\n[ ]  dmcmd.0002_second\n"
        # test_showmigrations_unmigrated_app / an unknown app label
        @test_throws "No installed app with label 'nonexistent_app'." DM.showmigrations("nonexistent_app"; io = devnull)
        # test_migrate_check (unapplied migrations: false, the CLI's exit status 1)
        @test migrate(; app = "dmcmd", target = "0002_second", check = true) == false
        @test !("dmcmd_author" in dm_tables())
        # test_migrate_plan
        plan = quiet(() -> migrate(; app = "dmcmd", target = "0002_second", plan_only = true))
        @test first.(plan) == [("dmcmd", "0001_initial"), ("dmcmd", "0002_second")] && !("dmcmd_author" in dm_tables())
        # test_sqlmigrate_forwards, test_sqlmigrate_backwards
        @test occursin("CREATE TABLE", sqlmigrate("dmcmd", "0001")) && occursin("dmcmd_author", sqlmigrate("dmcmd", "0001"))
        @test occursin("DROP TABLE", sqlmigrate("dmcmd", "0001"; backwards = true))
        # test_migrate
        quiet(() -> migrate(; app = "dmcmd", target = "0002_second"))
        @test issubset(["dmcmd_author", "dmcmd_book"], dm_tables()) && haskey(dm_cols("dmcmd_author"), "rating")
        @test sprint(io -> DM.showmigrations("dmcmd"; io = io)) == "dmcmd\n [X] 0001_initial\n [X] 0002_second\n"
        @test migrate(; app = "dmcmd", target = "0002_second", check = true) == true
        # (migrating back to a migration unapplies the later ones)
        quiet(() -> migrate(; app = "dmcmd", target = "0001_initial"))
        @test "dmcmd_author" in dm_tables() && !("dmcmd_book" in dm_tables()) && !haskey(dm_cols("dmcmd_author"), "rating")
        @test sprint(io -> DM.showmigrations("dmcmd"; plan = true, io = io)) == "[X]  dmcmd.0001_initial\n[ ]  dmcmd.0002_second\n"
        # test_migrate_zero (unapply everything)
        quiet(() -> migrate(; app = "dmcmd", target = "zero"))
        @test !("dmcmd_author" in dm_tables())
        # test_migrate_fake_initial / test_migrate_fake (recorded, not run)
        quiet(() -> migrate(; app = "dmcmd", target = "0001_initial", fake = true))
        @test ("dmcmd", "0001_initial") in DM.applied_migrations() && !("dmcmd_author" in dm_tables())
        quiet(() -> migrate(; app = "dmcmd", target = "zero", fake = true))
        @test !(("dmcmd", "0001_initial") in DM.applied_migrations())
        # test_showmigrations_squashed: a squashed migration shows how many it replaces
        wm("0001_squashed_0002", """Migration(initial = true, replaces = [("dmcmd", "0001_initial"), ("dmcmd", "0002_second")], operations = [
            CreateModel("dmcmd_author"; columns = [Column("name", :string; max_length = 255), Column("rating", :int; default = 0)]),
            CreateModel("dmcmd_book"; columns = [Column("author_id", :fk; references = "dmcmd_author")])])""")
        @test sprint(io -> DM.showmigrations("dmcmd"; io = io)) == "dmcmd\n [ ] 0001_squashed_0002 (2 squashed migrations)\n"
        quiet(() -> migrate(; app = "dmcmd", target = "0001_squashed_0002"))
        @test sprint(io -> DM.showmigrations("dmcmd"; io = io)) == "dmcmd\n [X] 0001_squashed_0002 (2 squashed migrations)\n"
        @test issubset(["dmcmd_author", "dmcmd_book"], dm_tables())
        quiet(() -> migrate(; app = "dmcmd", target = "zero"))
        @test !("dmcmd_author" in dm_tables())
        # (makemigrations numbers after a squashed migration by the last one it replaces)
        @test DM.next_number(DM.build_graph(), "dmcmd") == 3
        # not translated: the makemigrations, squashmigrations and optimizemigration tests (in
        # migrations.jl); verbosity and color options; test_sqlmigrate_* for non-atomic and
        # transactional DDL details; test_migrate_syncdb_* (migrate --sync, in migrations.jl)
    finally
        for t in ["dmcmd_book", "dmcmd_author"]
            t in dm_tables() && Juango.execute("DROP TABLE $(Juango.quote_name(Juango.backend(), t))")
        end
        Juango.execute("DELETE FROM juango_migrations WHERE app = 'dmcmd'")
        configure!(MIGRATION_MODULES = old)
    end
end

# --- test_loader / test_executor ---------------------------------------------------------------------

@testset "django migrations: test_loader" begin
    dirs = Dict(a => mktempdir() for a in ("dml1", "dml2", "dml3"))
    old = Juango.settings.MIGRATION_MODULES
    configure!(MIGRATION_MODULES = merge(old, dirs))
    quiet(f) = redirect_stdout(f, devnull)
    wm(app, name, code) = write(joinpath(dirs[app], name * ".jl"), "using Juango.Migrations\n" * code)
    try
        wm("dml1", "0001_initial", """Migration(initial = true, operations = [CreateModel("dml1_a")])""")
        wm("dml1", "0002_second", """Migration(dependencies = [("dml1", "0001_initial")], operations = [AddField("dml1_a", Column("x", :int; null = true))])""")
        # test_first: a dependency on another app's __first__ / __latest__ migration
        wm("dml2", "0001_initial", """Migration(dependencies = [("dml1", "__first__")], operations = [CreateModel("dml2_b")])""")
        wm("dml2", "0002_second", """Migration(dependencies = [("dml2", "0001_initial"), ("dml1", "__latest__")], operations = [])""")
        # test_run_before: dml3.0001 must run before dml1.0002
        wm("dml3", "0001_initial", """Migration(run_before = [("dml1", "0002_second")], operations = [CreateModel("dml3_c")])""")
        g = DM.build_graph(["dml1", "dml2", "dml3"]; applied = Set{Tuple{String,String}}())
        @test g.nodes[("dml2", "0001_initial")].dependencies == [("dml1", "0001_initial")]
        @test ("dml1", "0002_second") in g.nodes[("dml2", "0002_second")].dependencies
        @test ("dml3", "0001_initial") in g.nodes[("dml1", "0002_second")].dependencies
        order = DM.topo_order(g)
        @test findfirst(==(("dml3", "0001_initial")), order) < findfirst(==(("dml1", "0002_second")), order)
        # test_load_unmigrated_dependency (a __first__ of an app with no migrations goes away)
        wm("dml3", "0002_second", """Migration(dependencies = [("dml3", "0001_initial"), ("nomigrations", "__first__")], operations = [])""")
        g = DM.build_graph(["dml1", "dml2", "dml3"]; applied = Set{Tuple{String,String}}())
        @test g.nodes[("dml3", "0002_second")].dependencies == [("dml3", "0001_initial")]
        rm(joinpath(dirs["dml3"], "0002_second.jl"))
        # test_name_match (a migration by a prefix of its name), and an ambiguous or unknown one
        @test DM.resolve_name(g, "dml1", "0002") == ("dml1", "0002_second")
        @test_throws DM.MigrationError DM.resolve_name(g, "dml1", "00")
        @test_throws DM.MigrationError DM.resolve_name(g, "dml1", "nonexistent")
        # test_ignore_files (only NNNN_name.jl files are migrations)
        write(joinpath(dirs["dml1"], "notes.jl"), "error(\"not a migration\")")
        write(joinpath(dirs["dml1"], "_0003_private.jl"), "error(\"not a migration\")")
        @test sort(last.(filter(k -> k[1] == "dml1", collect(keys(DM.build_graph(["dml1"]; applied = Set{Tuple{String,String}}()).nodes))))) ==
              ["0001_initial", "0002_second"]
        # test_load_import_error / test_invalid (a file that doesn't evaluate to a Migration)
        write(joinpath(dirs["dml1"], "0009_broken.jl"), "using Juango.Migrations\n42")
        @test_throws DM.MigrationError DM.build_graph(["dml1"]; applied = Set{Tuple{String,String}}())
        rm(joinpath(dirs["dml1"], "0009_broken.jl"))
        # test_check_consistent_history: an applied migration whose dependency isn't
        quiet(() -> migrate(; app = "dml1", target = "0002_second", fake = true))
        DM.record_unapplied!(("dml1", "0001_initial"))
        @test_throws "Migration dml1.0002_second is applied before its dependency dml1.0001_initial on database 'default'." quiet(() -> migrate(; app = "dml1", target = "0002_second"))
        DM.record_unapplied!(("dml1", "0002_second"))
        # test_marked_as_migrated / unmigrated: apps with and without migration files
        @test "dml1" in DM.migrated_apps() && !("nomigrations" in DM.migrated_apps())
        # not translated: test_load_module_file, test_loading_namespace_package, test_explicit_missing_module
        # (Python packaging); the squashed-loading tests (in migrations.jl and test_commands above)
    finally
        Juango.execute("DELETE FROM juango_migrations WHERE app IN ('dml1', 'dml2', 'dml3')")
        configure!(MIGRATION_MODULES = old)
    end
end

# --- tests/schema: the schema editor, through the operations, with data in the tables ---------------

@testset "django schema" begin
    S = Juango.SchemaState()
    q(t) = Juango.quote_name(Juango.backend(), t)
    drop(ts...) = for t in ts
        t in dm_tables() && Juango.execute("DROP TABLE $(q(t))")
    end
    rows(sql) = Juango.execute(sql)
    # test_creation_deletion_reserved_names (a table and columns named with SQL keywords)
    op = DM.CreateModel("select"; columns = [dmcol("when"), dmcol("order"; null = true)])
    st = dm_run!(S, op)
    dm_insert("select", :when => 1)
    @test only(rows("SELECT $(q("when")) FROM $(q("select"))"))[:when] == 1
    dm_run!(S, op; backwards = true)
    @test !("select" in dm_tables())
    # test_fk (the constraint is enforced)
    st = dm_run!(S, DM.CreateModel("sc_author"; columns = [dmstr("name")]),
                 DM.CreateModel("sc_book"; columns = [dmcol("author_id", :fk; references = "sc_author"), dmstr("title")]))
    try
        @test dm_fk("sc_book", "author_id", "sc_author")
        @test dm_fails(() -> dm_insert("sc_book", :author_id => 9999, :title => "x"))     # (SQLite too since #260)
        dm_insert("sc_author", :name => "Ann")
        aid = only(rows("SELECT id FROM sc_author"))[:id]
        dm_insert("sc_book", :author_id => aid, :title => "Book")
        # test_add_field_temp_default (existing rows get the default)
        st2 = dm_run!(st, DM.AddField("sc_author", Juango.Column("surname", :string; max_length = 15, default = "Godwin")))
        @test only(rows("SELECT surname FROM sc_author"))[:surname] == "Godwin"
        # test_add_field_temp_default_boolean
        st2 = dm_run!(st2, DM.AddField("sc_author", dmcol("awesome", :bool; default = false)))
        @test only(rows("SELECT awesome FROM sc_author"))[:awesome] in (false, 0)
        # test_add_field_durationfield_with_default
        st2 = dm_run!(st2, DM.AddField("sc_author", dmcol("duration", :duration; default = Dates.Minute(10), null = true)))
        @test haskey(dm_cols("sc_author"), "duration")
        # test_add_field_binary
        st2 = dm_run!(st2, DM.AddField("sc_author", dmcol("bits", :binary; default = UInt8[0x01, 0x02], null = true)))
        @test haskey(dm_cols("sc_author"), "bits")
        # test_alter_char_field_decrease_length (the data fits)
        st2 = dm_run!(st2, DM.AlterField("sc_author", Juango.Column("name", :string; max_length = 10)))
        @test only(rows("SELECT name FROM sc_author"))[:name] == "Ann"
        # test_alter_textual_field_keep_null_status, test_alter_charfield_to_null
        st2 = dm_run!(st2, DM.AlterField("sc_author", Juango.Column("name", :string; max_length = 10, null = true)))
        @test dm_cols("sc_author")["name"].null
        dm_insert("sc_author", :name => nothing, :surname => "x", :awesome => false, :duration => nothing, :bits => nothing) |> _ -> nothing
        # test_alter_null_to_not_null (with a default, existing NULLs take it)
        Juango.execute("UPDATE sc_author SET name = NULL WHERE surname = 'x'")
        st2 = dm_run!(st2, DM.AlterField("sc_author", Juango.Column("name", :string; max_length = 10, default = "Unknown")))
        @test !dm_cols("sc_author")["name"].null
        @test Set(r[:name] for r in rows("SELECT name FROM sc_author")) == Set(["Ann", "Unknown"])
        Juango.execute("DELETE FROM sc_author WHERE surname = 'x'")
        # test_alter_numeric_field_keep_null_status, test_alter_text_field
        st2 = dm_run!(st2, DM.AddField("sc_book", dmcol("pages"; null = true)), DM.AlterField("sc_book", dmcol("pages", :bigint; null = true)))
        @test dm_cols("sc_book")["pages"].null
        # test_alter_text_field_to_date_field, _to_datetime_field, _to_time_field (empty columns)
        st2 = dm_run!(st2, DM.AddField("sc_book", dmcol("info", :text; null = true)))
        for k in (:date, :datetime, :time)
            st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("info", k; null = true)))
            st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("info", :text; null = true)))
        end
        @test haskey(dm_cols("sc_book"), "info")
        # test_alter_fk_to_o2o, test_alter_o2o_to_fk (the unique constraint comes and goes, the fk stays)
        st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("author_id", :fk; references = "sc_author", unique = true)))
        @test dm_unique("sc_book", ["author_id"]) && dm_fk("sc_book", "author_id", "sc_author")
        @test dm_fails(() -> dm_insert("sc_book", :author_id => aid, :title => "Second"))
        st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("author_id", :fk; references = "sc_author")))
        @test !dm_unique("sc_book", ["author_id"]) && dm_fk("sc_book", "author_id", "sc_author")
        # test_alter_field_fk_keeps_index
        st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("author_id", :fk; references = "sc_author", index = true)))
        st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("author_id", :fk; references = "sc_author", index = true, null = true)))
        @test dm_index("sc_book", ["author_id"]) && dm_fk("sc_book", "author_id", "sc_author")
        # test_alter_to_fk, test_alter_fk (an integer column becomes a foreign key, and back)
        st2 = dm_run!(st2, DM.AddField("sc_book", dmcol("editor_id", :bigint; null = true)))
        st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("editor_id", :fk; references = "sc_author", null = true)))
        @test dm_fk("sc_book", "editor_id", "sc_author")
        st2 = dm_run!(st2, DM.AlterField("sc_book", dmcol("editor_id", :bigint; null = true)))
        @test !dm_fk("sc_book", "editor_id", "sc_author")
        # test_unique (a column made unique, and not)
        st2 = dm_run!(st2, DM.AlterField("sc_book", Juango.Column("title", :string; max_length = 255, unique = true)))
        @test dm_unique("sc_book", ["title"]) && dm_fails(() -> dm_insert("sc_book", :author_id => aid, :title => "Book"))
        st2 = dm_run!(st2, DM.AlterField("sc_book", Juango.Column("title", :string; max_length = 255)))
        @test !dm_unique("sc_book", ["title"])
        # test_unique_together_with_fk
        st2 = dm_run!(st2, DM.AlterUniqueTogether("sc_book", [["author_id", "title"]]))
        @test dm_unique("sc_book", ["author_id", "title"])
        st2 = dm_run!(st2, DM.AlterUniqueTogether("sc_book", []))
        @test !dm_unique("sc_book", ["author_id", "title"]) && dm_fk("sc_book", "author_id", "sc_author")
        # test_rename_keep_null_status, test_rename (data kept)
        st2 = dm_run!(st2, DM.RenameField("sc_book", "pages", "page_count"))
        @test dm_cols("sc_book")["page_count"].null && !haskey(dm_cols("sc_book"), "pages")
        st2 = dm_run!(st2, DM.RenameField("sc_book", "title", "display"))
        @test only(rows("SELECT display FROM sc_book"))[:display] == "Book"
        # test_add_indexed_charfield, test_add_unique_charfield, test_text_field_with_db_index
        st2 = dm_run!(st2, DM.AddField("sc_book", Juango.Column("isbn", :string; max_length = 20, null = true, index = true)),
                      DM.AddField("sc_book", Juango.Column("code", :string; max_length = 20, null = true, unique = true)),
                      DM.AddField("sc_book", dmcol("blurb", :text; null = true, index = true)))
        @test dm_index("sc_book", ["isbn"]) && dm_unique("sc_book", ["code"])
        @test dm_mysql() || dm_index("sc_book", ["blurb"])
        # test_remove_indexed_field
        st2 = dm_run!(st2, DM.RemoveField("sc_book", "isbn"))
        @test !haskey(dm_cols("sc_book"), "isbn")
        # test_check_constraints (enforced, and removable)
        st2 = dm_run!(st2, DM.AddConstraint("sc_book", Juango.ConstraintSpec(:check, "sc_book_pages_positive"; condition = Q(page_count__gte = 0))))
        @test dm_fails(() -> Juango.execute("UPDATE sc_book SET page_count = -1"))
        st2 = dm_run!(st2, DM.RemoveConstraint("sc_book", "sc_book_pages_positive"))
        Juango.execute("UPDATE sc_book SET page_count = -1")
        @test only(rows("SELECT page_count FROM sc_book"))[:page_count] == -1
        # test_alter_autofield_pk_to_bigautofield_pk, _to_smallautofield_pk (with a foreign key pointing at it)
        st2 = dm_run!(st2, DM.AlterPrimaryKey("sc_author", :smallauto))
        @test dm_fk("sc_book", "author_id", "sc_author")
        st2 = dm_run!(st2, DM.AlterPrimaryKey("sc_author", :auto))
        @test dm_fk("sc_book", "author_id", "sc_author") && dm_count("sc_book") == 1
        # test_db_table (a renamed table keeps its rows and the foreign keys to it)
        st2 = dm_run!(st2, DM.RenameModel("sc_author", "sc_writer"))
        @test dm_count("sc_writer") == 1 && dm_fk("sc_book", "author_id", "sc_writer")
        st2 = dm_run!(st2, DM.RenameModel("sc_writer", "sc_author"))
        # test_db_comment_table, test_alter_db_comment (PostgreSQL and MySQL keep comments)
        if Juango.backend() isa Union{Juango.PostgresBackend,Juango.MySQLBackend}
            st2 = dm_run!(st2, DM.AlterModelTableComment("sc_book", "Books"), DM.AlterField("sc_book", Juango.Column("display", :string; max_length = 255, comment = "Shown")))
            @test st2["sc_book"].comment == "Books"
        end
    finally
        drop("sc_book", "sc_author", "sc_writer")
    end
    # test_foreign_key_index_long_names_regression, test_add_foreign_key_long_names (names past 63 bytes)
    long1, long2 = "sc_" * "a"^55, "sc_" * "b"^55
    st = dm_run!(S, DM.CreateModel(long1; columns = [dmstr("name")]),
                 DM.CreateModel(long2; columns = [dmcol("author_with_an_extremely_long_column_name_for_testing_id", :fk; references = long1, index = true)]))
    try
        @test dm_fk(long2, "author_with_an_extremely_long_column_name_for_testing_id", long1)
        @test all(k -> ncodeunits(k) <= 64, keys(dm_cons(long2)))
    finally
        drop(long2, long1)
    end
    # test_order_index (a descending index)
    st = dm_run!(S, DM.CreateModel("sc_ordered"; columns = [dmstr("name")]))
    try
        st = dm_run!(st, DM.AddIndex("sc_ordered", Juango.Index("-name"; name = "sc_ordered_name_desc")))
        @test dm_named("sc_ordered", "sc_ordered_name_desc")
    finally
        drop("sc_ordered")
    end
    # not translated: the m2m tests (join tables are tables, covered above); proxy, o2o-to-autofield,
    # db_on_delete and ForeignObject tests; the array, JSON, collation and generated-field tests (in
    # migrations.jl and db.jl); nulls_distinct (#232); changing a
    # primary key's type (#259); tests of the schema editor's Python API (context manager, deferred SQL)
end
