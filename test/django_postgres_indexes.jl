# Django's postgres_tests test_indexes, ported (#227). The index classes (GinIndex, GistIndex, BrinIndex, BTreeIndex,
# HashIndex, SpGistIndex, BloomIndex), their storage parameters and operator classes are PostgreSQL's: the tests that
# build indexes run there; the arguments' checks and suffixes run everywhere.
# julia --project=test test/django_postgres_indexes.jl   (see setup.jl)
#
# Not translated: the deconstruct() tests (Python's migration serializer; a migration file's Index code is tested
# instead), test_custom_suffix and test_custom_sql (subclasses of PostgresIndex), test_op_class_descending_collation
# (needs an ICU collation), and references_column (Django's Statement object).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DixCharFieldModel
    field = CharField(max_length = 64)
    Meta(table = "dix_charfieldmodel")
end
@model struct DixTextFieldModel
    field = TextField()
    Meta(table = "dix_textfieldmodel")
end
@model struct DixIntegerArrayModel
    field = ArrayField(BigIntegerField(); default = Vector{Int}, blank = true)
    Meta(table = "dix_integerarraymodel")
end
@model struct DixScene
    scene = TextField()
    setting = CharField(max_length = 255)
    Meta(table = "dix_scene")
end
const DIX_MODELS = [DixCharFieldModel, DixTextFieldModel, DixIntegerArrayModel, DixScene]
const DIX_PG = Juango.backend() isa Juango.PostgresBackend
redirect_stdout(devnull) do
    DIX_PG && foreach(e -> Juango.execute("CREATE EXTENSION IF NOT EXISTS $e"), ("pg_trgm", "bloom", "btree_gin", "btree_gist"))   # (GIN and GiST on plain columns, as Django's postgres_tests install)
    Juango.sync_models!(DIX_MODELS); append!(PORT_MODELS, DIX_MODELS)
end
dix_table(T) = Juango.modelmeta(T).table
dix_sql(T, ix) = only(Juango.index_spec_sql(Juango.backend(), dix_table(T), Juango.index_state(T, ix)))
dix_add!(T, ix) = foreach(Juango.execute, Juango.index_spec_sql(Juango.backend(), dix_table(T), Juango.index_state(T, ix)))
dix_remove!(T, ix) = foreach(Juango.execute, Juango.drop_index_spec_sql(Juango.backend(), dix_table(T), Juango.index_state(T, ix)))
dix_constraints(T) = Juango.introspect_constraints(dix_table(T))
const DIX_OPCLASS_QUERY = """SELECT opcname, c.relname FROM pg_opclass AS oc JOIN pg_index as i on oc.oid = ANY(i.indclass)
                             JOIN pg_class as c on c.oid = i.indexrelid WHERE c.relname = ?"""
dix_opclasses(name) = sort([(String(r[:opcname]), String(r[:relname])) for r in Juango.execute(DIX_OPCLASS_QUERY, [name])])
"Add the index, check it, drop it, check it's gone (most of Django's SchemaTests)."
function dix_roundtrip(f, T, ix)
    dix_add!(T, ix)
    c = dix_constraints(T)
    @test haskey(c, ix.name)
    haskey(c, ix.name) && f(c[ix.name])
    dix_remove!(T, ix)
    @test !haskey(dix_constraints(T), ix.name)
end

port_block() do
    @testset "django postgres_tests test_indexes: index classes" begin
        classes = [(BloomIndex, "bloom"), (BrinIndex, "brin"), (BTreeIndex, "btree"), (GinIndex, "gin"), (GistIndex, "gist"),
                   (HashIndex, "hash"), (SpGistIndex, "spgist")]
        for (C, suffix) in classes
            @test C(fields = ["title"], name = "test_title_$suffix").suffix == suffix                    # test_suffix
            # test_name_auto_generation (Django's names: INDEX_NAMES = :django)
            name = override_settings(INDEX_NAMES = :django) do
                Juango.index_state(DixCharFieldModel, C(fields = ["field"])).name
            end
            @test occursin(Regex("^dix_charfie_field_[0-9a-f]{6}_$suffix\$"), name)
        end
        @test Index(fields = ["title"], name = "x").suffix == "idx"
        # test_deconstruction: the index's code in a migration file
        code(ix) = Juango.Migrations.index_code(Juango.index_state(DixScene, ix))
        @test code(GinIndex(fields = ["scene"], name = "test_title_gin", fastupdate = true, gin_pending_list_limit = 128)) ==
              "Index([\"scene\"]; name = \"test_title_gin\", method = :gin, params = Pair{String,Any}[\"gin_pending_list_limit\" => 128, \"fastupdate\" => \"on\"])"
        @test code(BTreeIndex(fields = ["scene"], name = "test_title_btree", fillfactor = 80, deduplicate_items = false)) ==
              "Index([\"scene\"]; name = \"test_title_btree\", params = Pair{String,Any}[\"fillfactor\" => 80, \"deduplicate_items\" => \"off\"], suffix = \"btree\")"
        @test code(BloomIndex(fields = ["scene"], name = "test_bloom", length = 80, columns = [4])) ==
              "Index([\"scene\"]; name = \"test_bloom\", method = :bloom, params = Pair{String,Any}[\"length\" => 80, \"col1\" => 4])"
        @test code(GinIndex(Lower(:scene), name = "test_title_gin")) ==                                 # (..._with_expressions_no_customization)
              "Index(String[]; name = \"test_title_gin\", method = :gin, expressions = [(\"LOWER\", \"scene\")])"
        x = BrinIndex(fields = ["title"], name = "test_title_brin", autosummarize = true, pages_per_range = 16)
        @test x.params == ["autosummarize" => "on", "pages_per_range" => 16]
        x = GistIndex(fields = ["title"], name = "test_title_gist", buffering = false, fillfactor = 80)
        @test x.params == ["buffering" => "off", "fillfactor" => 80]
        @test HashIndex(fields = ["title"], name = "test_title_hash", fillfactor = 80).params == ["fillfactor" => 80]
        @test SpGistIndex(fields = ["title"], name = "test_title_spgist", fillfactor = 80).params == ["fillfactor" => 80]

        @test_throws "Bloom indexes support a maximum of 32 fields." BloomIndex(fields = fill("title", 33), name = "test_bloom")  # test_invalid_fields
        @test_throws "BloomIndex.columns must be a list or tuple." BloomIndex(fields = ["title"], name = "test_bloom", columns = "x")  # test_invalid_columns
        @test_throws "BloomIndex.columns cannot have more values than fields." BloomIndex(fields = ["title"], name = "test_bloom", columns = [4, 3])
        for n in (0, 4096)                                                                             # test_invalid_columns_value
            @test_throws "BloomIndex.columns must contain integers from 1 to 4095." BloomIndex(fields = ["title"], name = "test_bloom", columns = [n])
        end
        for n in (0, 4097)                                                                             # test_invalid_length
            @test_throws "BloomIndex.length must be None or an integer from 1 to 4096." BloomIndex(fields = ["title"], name = "test_bloom", length = n)
        end
        @test_throws "pages_per_range must be None or a positive integer" BrinIndex(fields = ["title"], name = "test_title_brin", pages_per_range = 0)
    end

    DIX_PG && @testset "django postgres_tests test_indexes: SchemaTests" begin
        @test !haskey(dix_constraints(DixIntegerArrayModel), "field")
        dix_roundtrip(c -> @test(c.type == "gin"), DixIntegerArrayModel, GinIndex(fields = ["field"], name = "integer_array_model_field_gin"))  # test_gin_index
        dix_roundtrip(DixIntegerArrayModel, GinIndex(fields = ["field"], name = "integer_array_gin_fastupdate", fastupdate = false)) do c  # test_gin_fastupdate
            @test c.type == "gin" && c.options == ["fastupdate=off"]
        end
        # test_partial_gin_index (Django registers Length as a CharField lookup for it)
        Juango.register_transform(lhs -> "LENGTH($lhs)", "dix_length"; kinds = [:char, :text], output = :int)
        try
            ix = GinIndex(fields = ["field"], name = "char_field_gin_partial_idx", condition = Q(field__dix_length = 40))
            dix_roundtrip(c -> @test(c.type == "gin"), DixCharFieldModel, ix)
            ix = GinIndex(fields = ["field"], name = "char_field_gin_partial_idx", condition = Q(field__dix_length = 40),  # test_partial_gin_index_with_tablespace
                          db_tablespace = "pg_default")
            @test occursin("TABLESPACE \"pg_default\" ", dix_sql(DixCharFieldModel, ix))
            dix_roundtrip(c -> @test(c.type == "gin"), DixCharFieldModel, ix)
        finally
            Juango.unregister_lookup("dix_length")
        end
        ix = GinIndex(fields = ["field"], name = "integer_array_gin_params", fastupdate = true, gin_pending_list_limit = 64,  # test_gin_parameters
                      db_tablespace = "pg_default")
        @test occursin(") WITH (gin_pending_list_limit = 64, fastupdate = on) TABLESPACE", dix_sql(DixIntegerArrayModel, ix))
        dix_roundtrip(DixIntegerArrayModel, ix) do c
            @test c.type == "gin" && c.options == ["gin_pending_list_limit=64", "fastupdate=on"]
        end
        ix = GinIndex(OpClass(F(:scene), name = "gin_trgm_ops"), name = "trigram_op_class_gin")          # test_trigram_op_class_gin_index
        dix_add!(DixScene, ix)
        @test dix_opclasses("trigram_op_class_gin") == [("gin_trgm_ops", "trigram_op_class_gin")]
        @test dix_constraints(DixScene)["trigram_op_class_gin"].type == "gin"
        dix_remove!(DixScene, ix)
        @test !haskey(dix_constraints(DixScene), "trigram_op_class_gin")
        ix = GinIndex(Cast(:field, SearchVectorField()), name = "cast_search_vector_gin")                 # test_cast_search_vector_gin_index
        @test occursin("tsvector", lowercase(dix_sql(DixTextFieldModel, ix))) && occursin("\"field\"", dix_sql(DixTextFieldModel, ix))
        dix_roundtrip(c -> @test(c.type == "gin"), DixTextFieldModel, ix)
        dix_roundtrip(c -> @test(c.type == "bloom"), DixCharFieldModel, BloomIndex(fields = ["field"], name = "char_field_model_field_bloom"))  # test_bloom_index
        dix_roundtrip(DixCharFieldModel, BloomIndex(fields = ["field"], name = "char_field_model_field_bloom_params", length = 512, columns = [3])) do c  # test_bloom_parameters
            @test c.type == "bloom" && c.options == ["length=512", "col1=3"]
        end
        dix_roundtrip(DixCharFieldModel, BrinIndex(fields = ["field"], name = "char_field_model_field_brin", pages_per_range = 4)) do c  # test_brin_index
            @test c.type == "brin" && c.options == ["pages_per_range=4"]
        end
        dix_roundtrip(DixCharFieldModel, BrinIndex(fields = ["field"], name = "char_field_brin_params", autosummarize = true)) do c  # test_brin_parameters
            @test c.type == "brin" && c.options == ["autosummarize=on"]
        end
        @test !haskey(dix_constraints(DixCharFieldModel), "field")
        dix_roundtrip(c -> @test(c.type == "btree"), DixCharFieldModel, BTreeIndex(fields = ["field"], name = "char_field_model_field_btree"))  # test_btree_index
        dix_roundtrip(DixCharFieldModel, BTreeIndex(fields = ["field"], name = "integer_array_btree_parameters", fillfactor = 80,  # test_btree_parameters
                                                    deduplicate_items = false)) do c
            @test c.type == "btree" && c.options == ["fillfactor=80", "deduplicate_items=off"]
        end
        dix_roundtrip(c -> @test(c.type == "gist"), DixCharFieldModel, GistIndex(fields = ["field"], name = "char_field_model_field_gist"))  # test_gist_index
        dix_roundtrip(DixCharFieldModel, GistIndex(fields = ["field"], name = "integer_array_gist_buffering", buffering = true, fillfactor = 80)) do c  # test_gist_parameters
            @test c.type == "gist" && c.options == ["buffering=on", "fillfactor=80"]
        end
        dix_roundtrip(DixScene, GistIndex(name = "scene_gist_include_setting", fields = ["scene"], include = ["setting"])) do c  # test_gist_include
            @test c.type == "gist" && c.columns == ["scene", "setting"]
        end
        ix = GistIndex(OpClass(SearchVector(:scene, :setting; config = "english"), name = "tsvector_ops"), name = "tsvector_op_class_gist")  # test_tsvector_op_class_gist_index
        @test occursin("\"scene\"", dix_sql(DixScene, ix)) && occursin("\"setting\"", dix_sql(DixScene, ix))
        dix_roundtrip(c -> @test(c.type == "gist"), DixScene, ix)
        dix_roundtrip(c -> @test(c.index), DixScene, Index(SearchVector(:id, :scene; config = "english"), name = "test_search_vector"))  # test_search_vector
        dix_roundtrip(c -> @test(c.type == "hash"), DixCharFieldModel, HashIndex(fields = ["field"], name = "char_field_model_field_hash"))  # test_hash_index
        dix_roundtrip(DixCharFieldModel, HashIndex(fields = ["field"], name = "integer_array_hash_fillfactor", fillfactor = 80)) do c  # test_hash_parameters
            @test c.type == "hash" && c.options == ["fillfactor=80"]
        end
        dix_roundtrip(c -> @test(c.type == "spgist"), DixTextFieldModel, SpGistIndex(fields = ["field"], name = "text_field_model_field_spgist"))  # test_spgist_index
        dix_roundtrip(DixTextFieldModel, SpGistIndex(fields = ["field"], name = "text_field_model_spgist_fillfactor", fillfactor = 80)) do c  # test_spgist_parameters
            @test c.type == "spgist" && c.options == ["fillfactor=80"]
        end
        dix_roundtrip(DixScene, SpGistIndex(name = "scene_spgist_include_setting", fields = ["scene"], include = ["setting"])) do c  # test_spgist_include
            @test c.type == "spgist" && c.columns == ["scene", "setting"]
        end
        ix = Index(OpClass(Lower(:field), name = "text_pattern_ops"), name = "test_op_class")              # test_op_class
        dix_add!(DixTextFieldModel, ix)
        @test dix_opclasses("test_op_class") == [("text_pattern_ops", "test_op_class")]
        dix_remove!(DixTextFieldModel, ix)
        ix = Index(Desc(OpClass(Lower(:field), name = "text_pattern_ops")), name = "test_op_class_descending_partial",  # test_op_class_descending_partial
                   condition = Q(field__contains = "China"))
        dix_add!(DixTextFieldModel, ix)
        @test dix_opclasses("test_op_class_descending_partial") == [("text_pattern_ops", "test_op_class_descending_partial")]
        @test dix_constraints(DixTextFieldModel)["test_op_class_descending_partial"].orders == ["DESC"]
        dix_remove!(DixTextFieldModel, ix)
        ix = Index(OpClass(Desc(Lower(:field)), name = "text_pattern_ops"), name = "test_op_class_descending_partial_tablespace",  # ..._partial_tablespace
                   condition = Q(field__contains = "China"), db_tablespace = "pg_default")
        @test occursin("TABLESPACE \"pg_default\" ", dix_sql(DixTextFieldModel, ix))
        dix_add!(DixTextFieldModel, ix)
        @test dix_opclasses("test_op_class_descending_partial_tablespace") == [("text_pattern_ops", "test_op_class_descending_partial_tablespace")]
        @test dix_constraints(DixTextFieldModel)["test_op_class_descending_partial_tablespace"].orders == ["DESC"]
        dix_remove!(DixTextFieldModel, ix)
    end
end
