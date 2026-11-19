# Django's migrations tests, ported (#227): tests/migrations.
# julia --project=test test/django_migrations.jl   (see setup.jl)
#
# Juango's migrations work on tables and columns (`CreateModel("foo"; columns = [...])`) where
# Django's work on models and fields, and they carry no model options, managers or bases (an
# inheritance parent is a table). Each test keeps its Django name in a comment; tests about
# things Juango's migrations don't have are listed at the end of each testset.
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
        append!(actions, (backwards ? DM.backwards : DM.forwards)(ops[i], b, states[i], states[i+1], deferred))
    end
    append!(actions, deferred)
    b isa Juango.PostgresBackend && (actions = DM.settle_deferred_triggers(actions))
    Juango.atomic(() -> foreach(DM.run_action, actions))
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
    # test_create_model_with_deferred_unique_constraint, test_create_model_with_covering_unique_constraint (#232)
    @test_broken :deferrable in fieldnames(Juango.ConstraintSpec)
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
