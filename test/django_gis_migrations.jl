# Django's gis_tests gis_migrations tests, ported (#227): OperationTests and MigrateTests, on PostGIS: geometry columns
# added, removed and altered by migrations, with their spatial (GiST) indexes; makemigrations and migrate of GIS models.
# julia --project=test test/django_gis_migrations.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Juango's operations work on tables and columns (`AddField("gis_neighborhood", Column(...))`) where Django's work on
# models and fields. Not translated: rasters (Juango has none: test_add_raster_field, the NoRasterSupportTests),
# 3D geometries (test_add_3d_field_opclass, test_alter_geom_field_dim), MySQL's spatial-index rules, and
# GeometryColumns (Django's model of PostGIS's geometry_columns view; the view is read directly here).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

if IS_POSTGRES
const DGM = Juango.Migrations
dgm_q(s) = Juango.quote_name(Juango.backend(), s)
"Run operations from state `st`; the state after (as Django's apply_operations)."
function dgm_run!(st, ops...)
    b = Juango.backend()
    for op in ops
        st2 = DGM.state_forwards!(op, Juango.copy_state(st), "gis")
        Juango.schema_atomic(() -> foreach(DGM.run_action, DGM.forwards(op, b, st, st2, String[])))
        st = st2
    end
    st
end
dgm_geom(name, type; srid = 4326, index = true, null = false) =
    Juango.Column(name, :geometry; of = Symbol("$(type):$(srid)"), index = index, null = null)
"Django's set_up_test_model: gis_neighborhood (name, geom MULTIPOLYGON), dropped afterwards."
function dgm_neighborhood(f)
    t = "gis_neighborhood"
    st = dgm_run!(Juango.SchemaState(), DGM.CreateModel(t; columns = [Juango.Column("name", :string; max_length = 100, unique = true),
                                                                      dgm_geom("geom", "MULTIPOLYGON")]))
    try
        f(st, t)
    finally
        t in Juango.introspect_tables() && Juango.execute("DROP TABLE $(dgm_q(t))")
    end
end
dgm_columns(t) = [c.name for c in Juango.introspect_columns(t)]
dgm_spatial_index(t, col) = any(v -> v.index && v.columns == [col], values(Juango.introspect_constraints(t)))
dgm_geometry_columns(t) = [String(r[:f_geometry_column]) => (String(r[:type]), Int(r[:srid]))
                           for r in Juango.execute("SELECT f_geometry_column, type, srid FROM geometry_columns WHERE f_table_name = ? ORDER BY 1", Any[t])]

@testset "django gis_tests gis_migrations: OperationTests" begin
    # test_add_geom_field
    dgm_neighborhood() do st, t
        st = dgm_run!(st, DGM.AddField(t, dgm_geom("path", "LINESTRING")))
        @test "path" in dgm_columns(t)
        @test dgm_geometry_columns(t) == ["geom" => ("MULTIPOLYGON", 4326), "path" => ("LINESTRING", 4326)]
        @test dgm_spatial_index(t, "path")
    end
    # test_add_blank_geom_field (a NULL column: null = true)
    dgm_neighborhood() do st, t
        st = dgm_run!(st, DGM.AddField(t, dgm_geom("path", "LINESTRING"; null = true)))
        @test "path" in dgm_columns(t) && only(filter(c -> c.name == "path", Juango.introspect_columns(t))).null
        @test dgm_spatial_index(t, "path")
    end
    # test_remove_geom_field
    dgm_neighborhood() do st, t
        st = dgm_run!(st, DGM.RemoveField(t, "geom"))
        @test !("geom" in dgm_columns(t)) && isempty(dgm_geometry_columns(t))
    end
    # test_create_model_spatial_index
    dgm_neighborhood() do st, t
        @test dgm_spatial_index(t, "geom")
        @test any(v -> v.columns == ["geom"] && lowercase(string(v.type)) in ("gist", "idx"), values(Juango.introspect_constraints(t)))
    end
    # test_alter_field_add_spatial_index / test_alter_field_remove_spatial_index
    dgm_neighborhood() do st, t
        st = dgm_run!(st, DGM.AddField(t, dgm_geom("point", "POINT"; index = false)))
        @test !dgm_spatial_index(t, "point")
        st = dgm_run!(st, DGM.AlterField(t, dgm_geom("point", "POINT"; index = true)))
        @test dgm_spatial_index(t, "point")
        st = dgm_run!(st, DGM.AlterField(t, dgm_geom("geom", "MULTIPOLYGON"; index = false)))
        @test !dgm_spatial_index(t, "geom")
    end
    # test_alter_field_with_spatial_index: another SRID, the index kept
    dgm_neighborhood() do st, t
        st = dgm_run!(st, DGM.AddField(t, dgm_geom("point", "POINT")))
        @test dgm_spatial_index(t, "point")
        st = dgm_run!(st, DGM.AlterField(t, dgm_geom("point", "POINT"; srid = 3086)))
        @test dgm_spatial_index(t, "point")
        @test ("point" => ("POINT", 3086)) in dgm_geometry_columns(t)
    end
    # test_add_check_constraint: a check on a geometry
    dgm_neighborhood() do st, t
        poly = Polygon([(0, 0), (0, 1), (1, 1), (1, 0), (0, 0)])
        st = dgm_run!(st, DGM.AddConstraint(t, Juango.ConstraintSpec(:check, "geom_within_constraint"; condition = Q(geom = MultiPolygon([poly])))))
        @test haskey(Juango.introspect_constraints(t), "geom_within_constraint")
    end
end

@testset "django gis_tests gis_migrations: MigrateTests" begin
    # test_migrate_gis: the migration's tables (geometry and geography columns) made, unmade (with their
    # geometry_columns rows) and made again
    tables = ["dgm_neighborhood", "dgm_household", "dgm_family"]
    ops = DGM.Operation[
        DGM.CreateModel("dgm_neighborhood"; columns = [Juango.Column("name", :string; max_length = 100, unique = true), dgm_geom("geom", "MULTIPOLYGON")]),
        DGM.CreateModel("dgm_household"; columns = [Juango.Column("neighborhood_id", :fk; null = true, references = "dgm_neighborhood"),
                                                    Juango.Column("address", :string; max_length = 100), Juango.Column("zip_code", :int; null = true),
                                                    Juango.Column("geom", :geometry; of = Symbol("POINT:4326:geog"), index = true)]),
        DGM.CreateModel("dgm_family"; columns = [Juango.Column("name", :string; max_length = 100, unique = true)]),
        DGM.AddField("dgm_household", Juango.Column("family_id", :fk; null = true, references = "dgm_family"))]
    b = Juango.backend()
    states = [Juango.SchemaState()]
    for op in ops
        push!(states, DGM.state_forwards!(op, Juango.copy_state(states[end]), "gis"))
    end
    run(dir) = Juango.schema_atomic() do
        for i in (dir === :forwards ? (1:length(ops)) : (length(ops):-1:1))
            foreach(DGM.run_action, (dir === :forwards ? DGM.forwards : DGM.backwards)(ops[i], b, states[i], states[i+1], String[]))
        end
    end
    try
        run(:forwards)
        @test all(t -> t in Juango.introspect_tables(), tables)
        @test dgm_geometry_columns("dgm_neighborhood") == ["geom" => ("MULTIPOLYGON", 4326)]
        @test only(Juango.execute("SELECT type, srid FROM geography_columns WHERE f_table_name = 'dgm_household'"))[:srid] == 4326
        run(:backwards)
        @test !any(t -> t in Juango.introspect_tables(), tables)
        @test isempty(dgm_geometry_columns("dgm_neighborhood")) && isempty(dgm_geometry_columns("dgm_household"))
        run(:forwards)
        @test all(t -> t in Juango.introspect_tables(), tables)
    finally
        for t in reverse(tables)
            t in Juango.introspect_tables() && Juango.execute("DROP TABLE $(dgm_q(t)) CASCADE")
        end
    end
end
end
