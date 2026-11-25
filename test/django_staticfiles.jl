# Django's staticfiles_tests, ported (#227, part): test_storage's TestHashedFiles and TestCollectionManifestStorage
# (manifest storage: references rewritten to hashed names, comments and strings skipped, fragments and queries kept,
# source maps, the passes limit, missing references), with Django's fixture files written out here.
# julia --project=test test/django_staticfiles.jl   (see setup.jl)
#
# Juango's hashes are SHA-256 (Django's MD5), so the expected names come from the manifest rather than literals.
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DSF_FILES = Dict(
    "test/file.txt" => "In STATICFILES_DIRS directory.\n",
    "cached/other.css" => "",
    "cached/styles.css" => "@import url(\"other.css\");\n",
    "cached/styles_insensitive.css" => "@IMporT uRL(\"other.css\");\n",
    "cached/import.css" => "@import 'styles.css';\n",
    "cached/url.css" => "@import url(\"https://www.djangoproject.com/m/css/base.css\");\n",
    "cached/img/relative.png" => "PNG1",
    "cached/css/img/window.png" => "PNG1",
    "cached/css/window.css" => "body {\n    background: #d3d6d8 url(\"img/window.png\");\n}\n",
    "cached/css/fonts/font.eot" => "EOT", "cached/css/fonts/font.svg" => "<svg/>",
    "cached/relative.css" => "@import url(\"../cached/styles.css\");\n@import url(\"absolute.css\");\n@import url(\"absolute.css#eggs\");\nbody {\n    background: #d3d6d8 url(img/relative.png);\n}\n",
    "cached/absolute.css" => "@import url(\"/static/cached/styles.css\");\n@import url(\"/static/styles_root.css\");\nbody {\n    background: #d3d6d8 url(/static/cached/img/relative.png);\n}\n",
    "styles_root.css" => "/* see cached/absolute.css and absolute_root.css */\n",
    "absolute_root.css" => "@import url(\"/static/styles_root.css\");\n",
    "cached/css/fragments.css" => """@font-face {
    font-family: "test";
    src: url('fonts/font.eot?#iefix') format('embedded-opentype'),
         url('fonts/font.svg#webfontIyfZbseF') format('svg'),
         url('fonts/font.svg#path/to/../../fonts/font.svg') format('svg'),
         url('data:font/woff;charset=utf-8;base64,d09GRgABAAAAADJoAA0AAAAAR2QAAQAAAAAAAAAAAAA');
}
div {
    behavior: url("#default#VML");
}
""",
    "cached/css/ignored.css" => """body {
    background: url("#foobar");
    background: url("http:foobar");
    background: url("https:foobar");
    background: url("data:foobar");
    background: url("chrome:foobar");
    background: url("//foobar");
    background: url();
}

/* @import url("non_exist.css") */

/* url("non_exist.png") */

/*

@import url("non_exist.css")

url("non_exist.png")

@import url(other.css)

*/

body {
    background: #d3d6d8 /*url("does.not.exist.png")*/ url(/static/cached/img/relative.png);
}

body {
    background: #d3d6d8 /* url("does.not.exist.png") */ url(/static/cached/img/relative.png) /*url("does.not.exist.either.png")*/;
}

body {
    content: "url(non_exist.png)";
    content: 'url(non_exist.png)';
}

/* Tailwind-style selector */
.tw\\:bg-\\[url\\(\\'non_exist.png\\'\\)\\] { background: url(../img/relative.png); }
body { font-family: 'sans-serif'; }
""",
    "cached/data_uri_with_nested_url.css" => "#example {\n    background-image: url(\"data:image/svg+xml,url(%23b) url(%23c)\");\n}\n",
    "cached/source_map.css" => "* {outline: 1px solid red;}\n/*# sourceMappingURL=source_map.css.map*/\n",
    "cached/source_map_tabs.css" => "* {outline: 1px solid red;}\n/*#\tsourceMappingURL=source_map.css.map\t*/\n",
    "cached/source_map_sensitive.css" => "* {outline: 1px solid red;}\n/*# sOuRcEMaPpInGURL=source_map.css.map */\n",
    "cached/source_map_data_uri.css" => "* {outline: 1px solid red;}\n/*# sourceMappingURL=data:application/json;charset=utf8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIl9zcmMv*/\n",
    "cached/source_map.css.map" => "{}", "cached/source_map.js.map" => "{}",
    "cached/source_map.js" => "//# sourceMappingURL=source_map.js.map\nlet a_variable = 1;\n",
    "cached/source_map_trailing_whitespace.js" => "//# sourceMappingURL=source_map.js.map\t \nlet a_variable = 1;\n",
    "cached/source_map_sensitive.js" => "//# sOuRcEMaPpInGURL=source_map.js.map\nlet a_variable = 1;\n",
    "cached/source_map_data_uri.js" => "//# sourceMappingURL=data:application/json;charset=utf8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIl9zcmMv\nlet a_variable = 1;\n",
    "test/nonascii.css" => "body { background: url('window.png'); }\n.snowman:before { content: \"☃\"; }\n",
    "test/window.png" => "PNG2")
function dsf_tree(files)
    d = mktempdir()
    for (k, v) in files
        mkpath(dirname(joinpath(d, k))); write(joinpath(d, k), v)
    end
    d
end
"collectstatic of these files into a new STATIC_ROOT: (root, manifest paths, stderr, error)."
function dsf_collect(files; kw...)
    src, root = dsf_tree(files), mktempdir()
    err = IOBuffer()
    e = override_settings(; STATIC_DIRS = [src], STATIC_ROOT = root, STATICFILES_STORAGE = :manifest, STATIC_URL = "/static/",
                          STATICFILES_FINDERS = Any[Juango.FileSystemFinder()], kw...) do
        try
            call_command("collectstatic"; stderr = err)
            nothing
        catch e
            e isa CommandError || rethrow()
            e
        end
    end
    mf = joinpath(root, "staticfiles.json")
    paths = isfile(mf) ? Dict{String,String}(Juango.JSON.parse(read(mf, String))["paths"]) : Dict{String,String}()
    (root, paths, String(take!(err)), e)
end

@testset "django staticfiles_tests: TestHashedFiles (manifest storage)" begin
    root, P, _, e = dsf_collect(DSF_FILES)
    @test e === nothing
    rd(n) = read(joinpath(root, P[n]), String)
    h(n) = basename(P[n])
    # test_template_tag_return: hashed names with DEBUG off; a directory as it is; a missing file is an error
    override_settings(STATIC_ROOT = root, STATICFILES_STORAGE = :manifest, DEBUG = false, STATIC_URL = "/static/") do
        @test Juango.static_url("test/file.txt") == "/static/" * P["test/file.txt"]
        @test Juango.static_url("cached/styles.css") == "/static/" * P["cached/styles.css"]
        @test Juango.static_url("path/") == "/static/path/" && Juango.static_url("path/?query") == "/static/path/?query"
        @test_throws "Missing staticfiles manifest entry for 'does/not/exist.png'" Juango.static_url("does/not/exist.png")
        # test_path_with_querystring, test_path_with_fragment
        @test Juango.static_url("cached/styles.css?spam=eggs") == "/static/" * P["cached/styles.css"] * "?spam=eggs"
        @test Juango.static_url("cached/styles.css#eggs") == "/static/" * P["cached/styles.css"] * "#eggs"
    end
    @test occursin(r"^test/file\.[0-9a-f]{12}\.txt$", P["test/file.txt"])
    # test_template_tag_simple_content: the reference rewritten, as url("...")
    c = rd("cached/styles.css")
    @test !occursin("cached/other.css", c) && occursin("@import url(\"$(h("cached/other.css"))\")", c)
    # test_css_import_case_insensitive
    @test occursin(h("cached/other.css"), rd("cached/styles_insensitive.css"))
    # test_path_ignored_completely: schemes, fragments, comments and strings are left alone
    c = rd("cached/css/ignored.css")
    for s in ("#foobar", "http:foobar", "https:foobar", "data:foobar", "chrome:foobar", "//foobar", "url()",
              "/* @import url(\"non_exist.css\") */", "/* url(\"non_exist.png\") */", "@import url(\"non_exist.css\")",
              "url(\"non_exist.png\")", "@import url(other.css)", "content: \"url(non_exist.png)\";", "content: 'url(non_exist.png)';")
        @test occursin(s, c)
    end
    png = h("cached/img/relative.png")
    @test occursin("background: #d3d6d8 /*url(\"does.not.exist.png\")*/ url(\"/static/cached/img/$png\");", c)
    @test occursin("background: #d3d6d8 /* url(\"does.not.exist.png\") */ url(\"/static/cached/img/$png\") /*url(\"does.not.exist.either.png\")*/", c)
    @test occursin(raw".tw\:bg-\[url\(\'non_exist.png\'\)\] { background: url(" * "\"../img/$png\"); }", c)
    # test_path_with_querystring_and_fragment
    c = rd("cached/css/fragments.css")
    eot, svg = h("cached/css/fonts/font.eot"), h("cached/css/fonts/font.svg")
    @test occursin("fonts/$eot?#iefix", c) && occursin("fonts/$svg#webfontIyfZbseF", c) && occursin("fonts/$svg#path/to/../../fonts/font.svg", c)
    @test occursin("data:font/woff;charset=utf-8;base64,d09GRgABAAAAADJoAA0AAAAAR2QAAQAAAAAAAAAAAAA", c) && occursin("#default#VML", c)
    # test_template_tag_absolute, test_template_tag_absolute_root
    c = rd("cached/absolute.css")
    @test !occursin("/static/cached/styles.css", c) && occursin("/static/cached/" * h("cached/styles.css"), c)
    @test occursin("/static/" * P["styles_root.css"], c) && occursin("/static/cached/img/$png", c)
    @test occursin("/static/" * P["styles_root.css"], rd("absolute_root.css"))
    # test_template_tag_relative: the path as written, the name hashed
    c = rd("cached/relative.css")
    @test !occursin("../cached/styles.css\"", c) && !occursin("url(img/relative.png)", c)
    @test occursin("url(\"img/$png\")", c) && occursin("../cached/" * h("cached/styles.css"), c) && occursin(h("cached/absolute.css") * "#eggs", c)
    # test_import_replacement, test_template_tag_deep_relative, test_template_tag_url
    @test occursin("import url(\"" * h("cached/styles.css") * "\")", rd("cached/import.css"))
    @test occursin("url(\"img/" * h("cached/css/img/window.png") * "\")", rd("cached/css/window.css"))
    @test occursin("https://", rd("cached/url.css"))
    # test_css_data_uri_with_nested_url
    @test occursin("url(\"data:image/svg+xml,url(%23b) url(%23c)\")", rd("cached/data_uri_with_nested_url.css"))
    # test_css_source_map, test_css_source_map_tabs, test_css_source_map_sensitive, test_css_source_map_data_uri
    cmap = "/*# sourceMappingURL=" * h("cached/source_map.css.map") * " */"
    @test occursin(cmap, rd("cached/source_map.css")) && !occursin("source_map.css.map*/", rd("cached/source_map.css"))
    @test occursin(cmap, rd("cached/source_map_tabs.css"))
    @test occursin("/*# sOuRcEMaPpInGURL=source_map.css.map */", rd("cached/source_map_sensitive.css"))
    @test occursin("/*# sourceMappingURL=data:application/json;charset=utf8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIl9zcmMv*/", rd("cached/source_map_data_uri.css"))
    # test_js_source_map, test_js_source_map_trailing_whitespace, test_js_source_map_sensitive, test_js_source_map_data_uri
    jmap = "//# sourceMappingURL=" * h("cached/source_map.js.map")
    @test occursin(jmap, rd("cached/source_map.js")) && occursin(jmap, rd("cached/source_map_trailing_whitespace.js"))
    @test !occursin("source_map.js.map\t", rd("cached/source_map_trailing_whitespace.js"))
    @test occursin("//# sOuRcEMaPpInGURL=source_map.js.map", rd("cached/source_map_sensitive.js"))
    @test occursin("//# sourceMappingURL=data:application/json;charset=utf8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIl9zcmMv", rd("cached/source_map_data_uri.js"))
    # test_post_processing (non-ASCII CSS is processed), and the originals are kept beside the hashed copies
    @test occursin("url(\"" * h("test/window.png") * "\")", rd("test/nonascii.css")) && occursin("☃", rd("test/nonascii.css"))
    @test isfile(joinpath(root, "cached", "styles.css"))
    # test_manifest_exists, test_loaded_cache (the manifest names each file)
    @test isfile(joinpath(root, "staticfiles.json")) && length(P) == length(DSF_FILES)
    # test_import_loop: references that never settle fail collectstatic
    _, _, err, e = dsf_collect(Dict("foo.css" => "@import url(\"bar.css\")\n", "bar.css" => "@import url(\"foo.css\")\n"))
    @test e isa CommandError && occursin("Max post-process passes exceeded", e.msg) && err == "Post-processing 'bar.css, foo.css' failed!\n\n"
    # test_post_processing_failure: a reference to a missing file (#293: an error only with STATICFILES_STRICT_REFERENCES)
    _, P2, err, e = dsf_collect(Dict("faulty.css" => "@import url(\"missing.css\");\n"); STATICFILES_STRICT_REFERENCES = true)
    @test e isa CommandError && occursin("The file 'missing.css' could not be found", e.msg) && err == "Post-processing 'faulty.css' failed!\n\n"
    _, P2, err, e = dsf_collect(Dict("faulty.css" => "@import url(\"missing.css\");\n"))
    @test_broken e isa CommandError                                    # (Django's default; Juango keeps the reference and warns, #293)
    @test e === nothing && haskey(P2, "faulty.css")
    # not translated: the hashes' literal values (Juango's are SHA-256), manifest_strict and manifest_hash, JS module
    # import aggregation (off by default in Django too), custom storages' read/save_manifest, file permissions,
    # TestExtraPatternsStorage (patterns aren't pluggable in Juango), and the finders/management/views tests
    # (collectstatic and findstatic are tested in views.jl)
end
