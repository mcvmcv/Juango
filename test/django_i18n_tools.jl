# Django's makemessages, compilemessages and JavaScript catalogue tests, ported (#227): tests/i18n
# test_extraction (BasicExtractorTests, TemplateExtractorTests, LocationCommentsTests, KeepPotFileExtractorTests,
# MultipleLocaleExtractionTests, ExcludedLocaleExtractionTests, CustomLayoutExtractionTests, NoSettingsExtractionTests),
# test_compilation (PoFileTests, PoFileContentsTests, MultipleLocaleCompilationTests, ExcludedLocaleCompilationTests,
# IgnoreDirectoryCompilationTests, CompilationErrorHandling, FuzzyTranslationTest), and view_tests' I18NViewTests
# and JavaScriptI18nTests for JavaScriptCatalog/JSONCatalog.
# julia --project=test test/django_i18n_tools.jl   (see setup.jl)
#
# Django runs xgettext/msgmerge/msgfmt over Python and templates; Juango extracts from Julia and templates itself,
# so the xgettext-specific tests (gettext versions, --keep-pot, symlinks, the JavaScript domain, python-format
# flags, %-escaping of template literals) aren't translated. The JavaScript tests run the script in Node when it's
# installed (Django: Selenium). Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

function dxt_project(files)
    root = mktempdir()
    for (name, body) in files
        p = joinpath(root, name)
        mkpath(dirname(p))
        write(p, body)
    end
    root
end
dxt_po(path) = Dict((e.context, e.msgid) => e for e in Juango.parse_po(read(path, String)))
dxt_write_po(path, header, body) = (mkpath(dirname(path)); write(path, "msgid \"\"\nmsgstr \"\"\n\"Content-Type: text/plain; charset=UTF-8\\n\"\n" *
                                                                      (isempty(header) ? "" : "\"$header\\n\"\n") * "\n" * body))

const DXT_TEMPLATE = """
{% load i18n %}
{% comment %}Translators: This comment should be extracted{% endcomment %}
{% translate "Translatable literal #1" %}
{# Translators: Django comment block for translators #}
{% translate "Translatable literal #2" %}
{# This comment shouldn't be extracted #}
{% translate "Translatable literal #3" %}
{# Translators: ignored i18n comment #1 #}{% translate "Translatable literal #4a" %}
{% translate "Translatable literal #5" noop %}
{% translate "Literal with a filter"|upper %}
{% translate "May" context "month name" %}
{% translate 'Single-quoted context' context 'Special' %}
{% blocktranslate context "verb" %}Book{% endblocktranslate %}
{% blocktranslate trimmed %}
  Text with a few
  line breaks.
{% endblocktranslate %}
{% blocktranslate count n=c %}{{ n }} apple{% plural %}{{ n }} apples{% endblocktranslate %}
{{ _("Literal in a variable")|upper }}
{% firstof _("Literal in a tag") x %}
<p>{% translate "Ünïcödé" %}</p>
"""
const DXT_JULIA = """
# Translators: This is a translator comment
greet() = gettext("Hello from Julia")
# a plain comment
plain() = gettext("No comment")
lazy() = gettext_lazy("Lazy string")
noop() = gettext_noop("Noop string")
ctx() = pgettext("month name", "May")
pl(n) = ngettext("%(n)d file", "%(n)d files", n)
npl(n) = npgettext("ctx", "%(n)d item", "%(n)d items", n)
multi() = gettext(
    "On the next line")
esc() = gettext("Quote \\"inside\\"")
# gettext("Commented out")
"""

@testset "django i18n: makemessages" begin
    root = dxt_project(["templates/test.html" => DXT_TEMPLATE, "app/views.jl" => DXT_JULIA,
                        "templates/skip.html~" => "{% translate \"Backup file\" %}", ".hidden/x.html" => "{% translate \"Hidden\" %}",
                        "ignored/x.html" => "{% translate \"Ignored dir\" %}", "static/a.js" => "gettext('In JavaScript')",
                        "templates/other.thtml" => "{% translate \"Other extension\" %}"])
    loc = joinpath(root, "locale")
    mm(lang = "de"; kw...) = Juango.makemessages(lang; root = root, locale_dir = loc, kw...)
    out = @test_logs (:warn, r"Translators: ignored i18n comment #1' \(file templates/test.html, line 8\) was ignored, because it wasn't the last item on the line") match_mode = :any mm()
    @test out == joinpath(loc, "de", "LC_MESSAGES", "juango.po")                       # test_po_file_header (the path)
    po, text = dxt_po(out), read(out, String)
    m(id, ctx = "") = get(po, (ctx, id), nothing)
    @test occursin("Language: de", text) && occursin("Plural-Forms: nplurals=2; plural=(n != 1);", text)
    @testset "BasicExtractorTests / TemplateExtractorTests" begin
        # test_comments_extractor
        @test occursin("#. Translators: This comment should be extracted\n#: templates/test.html:3\nmsgid \"Translatable literal #1\"", text)
        @test occursin("#. Translators: Django comment block for translators\n#: templates/test.html:5\nmsgid \"Translatable literal #2\"", text)
        @test !any(startswith("#."), m("Translatable literal #3").comments)
        @test m("Translatable literal #4a") !== nothing && !any(startswith("#."), m("Translatable literal #4a").comments)
        @test !occursin("shouldn't be extracted", text)
        @test m("Translatable literal #5") !== nothing                                   # (noop marks a string for translation)
        @test m("Literal with a filter") !== nothing                                     # test_template_message_context_extractor
        @test m("May", "month name") !== nothing && m("Single-quoted context", "Special") !== nothing && m("Book", "verb") !== nothing
        @test m("Text with a few line breaks.") !== nothing                              # test_blocktranslate_trimmed
        @test m("%(n)s apple").msgid_plural == "%(n)s apples" && length(m("%(n)s apple").msgstr) == 2
        @test m("Literal in a variable") !== nothing && m("Literal in a tag") !== nothing   # (_("..") literals)
        @test m("Ünïcödé") !== nothing                                                   # test_unicode_file_name / special chars
        # (Julia source: xgettext's keywords)
        @test occursin("#. Translators: This is a translator comment\n#: app/views.jl:2\nmsgid \"Hello from Julia\"", text)
        @test !any(startswith("#."), m("No comment").comments)
        @test m("Lazy string") !== nothing && m("Noop string") !== nothing && m("On the next line") !== nothing
        @test m("%(n)d file").msgid_plural == "%(n)d files" && m("%(n)d item", "ctx").msgid_plural == "%(n)d items"
        @test m("Quote \"inside\"") !== nothing && m("Commented out") === nothing
        @test "#: app/views.jl:7" in m("May", "month name").comments && "#: templates/test.html:11" in m("May", "month name").comments
        # test_makemessages_find_files: default extensions and ignore patterns
        @test m("Backup file") === nothing && m("Hidden") === nothing && m("In JavaScript") === nothing && m("Other extension") === nothing
        @test m("Ignored dir") !== nothing
    end
    @testset "ignore, extensions" begin
        po2 = dxt_po(mm(; ignore = ["ignored/*"]))                                       # test_ignore_directory
        @test !haskey(po2, ("", "Ignored dir")) && haskey(po2, ("", "Translatable literal #1"))
        @test !haskey(dxt_po(mm(; ignore = ["ignored"])), ("", "Ignored dir"))
        @test !haskey(dxt_po(mm(; ignore = ["*.html"])), ("", "Translatable literal #1"))   # test_ignore_file_patterns
        po3 = dxt_po(mm(; extensions = ["thtml"]))                                       # test_template_extension (-e)
        @test haskey(po3, ("", "Other extension")) && !haskey(po3, ("", "Translatable literal #1")) && haskey(po3, ("", "Hello from Julia"))
        @test haskey(dxt_po(mm(; extensions = ["html,thtml"])), ("", "Other extension"))
        @test haskey(dxt_po(mm(; no_default_ignore = true)), ("", "Hidden"))              # (--no-default-ignore)
    end
    @testset "LocationCommentsTests" begin
        t1 = read(mm(; no_location = true), String)                                      # test_no_location_enabled
        @test !occursin("#: ", t1) && occursin("#. Translators: This comment should be extracted\nmsgid", t1)
        t2 = read(mm(; add_location = "file"), String)                                   # test_add_location_file
        @test occursin("#: templates/test.html\n", t2) && !occursin("#: templates/test.html:", t2)
        @test !occursin("#: ", read(mm(; add_location = "never"), String))               # test_add_location_never
        @test occursin("#: templates/test.html:3\n", read(mm(; add_location = "full"), String))   # test_add_location_full
        @test_throws ArgumentError mm(; add_location = "nowhere")
    end
    @testset "keeping translations, obsolete entries" begin
        p = mm()
        write(p, replace(read(p, String), "msgid \"No comment\"\nmsgstr \"\"" => "msgid \"No comment\"\nmsgstr \"Kein Kommentar\""))
        @test dxt_po(mm())[("", "No comment")].msgstr == ["Kein Kommentar"]              # (existing translations kept)
        write(joinpath(root, "app", "views.jl"), replace(DXT_JULIA, "plain() = gettext(\"No comment\")\n" => ""))
        t = read(mm(), String)                                                           # (msgmerge: obsolete entries)
        @test occursin("#~ msgid \"No comment\"\n#~ msgstr \"Kein Kommentar\"", t) && !haskey(dxt_po(p), ("", "No comment"))
        write(joinpath(root, "app", "views.jl"), DXT_JULIA)
        @test dxt_po(mm())[("", "No comment")].msgstr == ["Kein Kommentar"]              # (back in the source: the translation too)
        write(joinpath(root, "app", "views.jl"), replace(DXT_JULIA, "plain() = gettext(\"No comment\")\n" => ""))
        @test !occursin("No comment", read(mm(; no_obsolete = true), String))           # (--no-obsolete)
        write(joinpath(root, "app", "views.jl"), DXT_JULIA)
    end
    @testset "plural forms" begin
        tpl = read(mm("pl"), String)                                                     # test_copy_plural_forms (gettext's rule)
        @test occursin("Language: pl", tpl) && occursin("Plural-Forms: nplurals=3;", tpl)
        @test length(dxt_po(joinpath(loc, "pl", "LC_MESSAGES", "juango.po"))[("", "%(n)s apple")].msgstr) == 3
        @test occursin("Plural-Forms: nplurals=1; plural=0;", read(mm("ja"), String))
        @test occursin("Language: pt_BR", read(mm("pt-br"), String))                     # (a language code: its locale)
        tpl2 = replace(tpl, "Plural-Forms: nplurals=3;" => "X-Custom: kept\\n\"\n\"Plural-Forms: nplurals=3;")
        write(joinpath(loc, "pl", "LC_MESSAGES", "juango.po"), tpl2)
        @test occursin("X-Custom: kept", read(mm("pl"), String))                         # (an existing header is kept)
    end
    @testset "MultipleLocaleExtractionTests / ExcludedLocaleExtractionTests" begin
        ps = mm(["fr", "it"])                                                            # test_multiple_locales
        @test ps == [joinpath(loc, l, "LC_MESSAGES", "juango.po") for l in ("fr", "it")] && all(isfile, ps)
        ps = Juango.makemessages(; all = true, exclude = ["it"], root = root, locale_dir = loc)   # test_all_locales / test_one_locale_excluded
        @test sort(basename.(dirname.(dirname.(ps)))) == ["de", "fr", "ja", "pl", "pt_BR"]
        ps = Juango.makemessages(; all = true, exclude = ["it", "fr"], root = root, locale_dir = loc)   # test_multiple_locales_excluded
        @test !any(p -> occursin("/fr/", p) || occursin("/it/", p), ps)
        ps = Juango.makemessages(["it"]; exclude = ["it"], root = root, locale_dir = loc)   # test_one_locale_excluded_with_locale
        @test isempty(ps)
        @test_throws ArgumentError Juango.makemessages(; root = root, locale_dir = loc)   # test_no_locale_raises
    end
    @testset "errors" begin
        bad = dxt_project(["templates/bad.html" => "{% load i18n %}\n{% blocktranslate %}{% if x %}y{% endif %}{% endblocktranslate %}"])
        e = try Juango.makemessages("de"; root = bad, locale_dir = joinpath(bad, "locale")) catch e; e end   # test_template_with_error
        @test e isa TemplateSyntaxError && occursin("Translation blocks must not include other block tags: if x (file templates/bad.html, line 2)", sprint(showerror, e))
        enc = dxt_project(["templates/latin1.html" => "{% translate \"caf\xe9\" %}", "templates/ok.html" => "{% translate \"Fine\" %}"])
        p = @test_logs (:warn, r"UnicodeDecodeError: skipped file latin1.html in templates") match_mode = :any Juango.makemessages("de"; root = enc, locale_dir = joinpath(enc, "locale"))   # test_unicode_decode_error
        @test haskey(dxt_po(p), ("", "Fine"))
        col = dxt_project(["templates/c.html" => "{% load i18n %}{% translate \"%(n)s pear\" %}{% blocktranslate count n=c %}{{ n }} pear{% plural %}{{ n }} pears{% endblocktranslate %}"])
        pc = dxt_po(Juango.makemessages("de"; root = col, locale_dir = joinpath(col, "locale")))   # test_trans_and_plural_blocktrans_collision
        @test count(k -> k[2] == "%(n)s pear", keys(pc)) == 1 && pc[("", "%(n)s pear")].msgid_plural == "%(n)s pears"
    end
    @testset "command options" begin
        o = Juango.i18n_command_options(["-l", "de", "--locale=fr,it", "-x", "it", "-e", "html,txt", "-i", "foo*", "--ignore", "bar",
                                         "--no-location", "--add-location=file", "-a", "-f"])
        @test o.locale == ["de", "fr", "it"] && o.exclude == ["it"] && o.extension == ["html,txt"] && o.ignore == ["foo*", "bar"]
        @test o.all && o.flag("no-location") && o.value("add-location") == "file" && o.flag("f") && !o.flag("no-obsolete")
    end
end

@testset "django i18n: compilemessages" begin
    d = mktempdir()
    po(l) = joinpath(d, l, "LC_MESSAGES", "juango.po")
    mo(l) = joinpath(d, l, "LC_MESSAGES", "juango.mo")
    dxt_write_po(po("de"), "", "msgid \"Hello\"\nmsgstr \"Hallo\"\n\nmsgid \"100% sure\"\nmsgstr \"100% sicher\"\n")
    dxt_write_po(po("fr"), "Plural-Forms: nplurals=2; plural=(n > 1);",
                 "msgid \"Hello\"\nmsgstr \"Bonjour\"\n\n#, fuzzy\nmsgid \"Lenght\"\nmsgstr \"Longueur\"\n")
    old_paths = get(settings, :LOCALE_PATHS, String[])
    configure!(LOCALE_PATHS = [d])
    try
        @test sort(Juango.compilemessages([d])) == sort([mo("de"), mo("fr")])           # test_percent_symbol_in_po_file (and the rest)
        @test with_language(() -> gettext("100% sure"), "de") == "100% sicher"
        @test isempty(Juango.compilemessages([d]))                                      # (up to date: skipped)
        touch(po("de"))
        @test Juango.compilemessages([d]) == [mo("de")]
        rm(mo("de")); rm(mo("fr"))
        @test Juango.compilemessages([d]; locale = "de") == [mo("de")] && !isfile(mo("fr"))   # test_one_locale (MultipleLocaleCompilationTests)
        rm(mo("de"))
        @test sort(Juango.compilemessages([d]; locale = ["de", "fr"])) == sort([mo("de"), mo("fr")])   # test_multiple_locales
        rm(mo("de")); rm(mo("fr"))
        @test Juango.compilemessages([d]; exclude = ["de"]) == [mo("fr")]               # test_one_locale_excluded
        rm(mo("fr"))
        @test Juango.compilemessages([d]; ignore = ["fr"]) == [mo("de")]                # test_ignores_based_on_pattern
        rm(mo("de"))
        Juango.compilemessages([d])                                                     # test_nofuzzy_compiling
        @test with_language(() -> gettext("Lenght"), "fr") == "Lenght" && with_language(() -> gettext("Hello"), "fr") == "Bonjour"
        rm(mo("fr"))
        Juango.compilemessages([d]; use_fuzzy = true)                                   # test_fuzzy_compiling
        @test with_language(() -> gettext("Lenght"), "fr") == "Longueur"

        mkpath(dirname(po("es")))                                                       # test_bom_rejection
        write(po("es"), vcat([0xef, 0xbb, 0xbf], Vector{UInt8}("msgid \"Hello\"\nmsgstr \"Hola\"\n")))
        rm(mo("de"))
        e = try Juango.compilemessages([d]) catch e; e end
        @test e isa Juango.CommandError && occursin("juango.po file has a BOM (Byte Order Mark)", e.msg) &&
              endswith(e.msg, "compilemessages generated one or more errors.")
        @test isfile(mo("de")) && !isfile(mo("es"))                                     # (the others are compiled)
        rm(joinpath(d, "es"); recursive = true)
        dxt_write_po(po("it"), "", "msgid \"Hello\"\nthis is not a po file\nmsgstr \"Ciao\"\n")   # test_error_reported_by_msgfmt
        e = try Juango.compilemessages([d]) catch e; e end
        @test e isa Juango.CommandError && occursin("it/LC_MESSAGES/juango.po:6: syntax error", e.msg) && !isfile(mo("it"))
        rm(joinpath(d, "it"); recursive = true)
        dxt_write_po(po("nl"), "", "msgid \"Hello\"\nmsgstr \"Hallo\"\n")                 # test_no_write_access
        chmod(dirname(po("nl")), 0o555)
        try
            e = try Juango.compilemessages([d]) catch e; e end
            @test e isa Juango.CommandError && occursin("seemingly not writable location", e.msg)
        finally
            chmod(dirname(po("nl")), 0o755)
        end
    finally
        configure!(LOCALE_PATHS = old_paths)
        Juango.reload_translations!()
    end
end

@testset "django i18n: JavaScriptCatalog (I18NViewTests)" begin
    d = mktempdir()
    dxt_write_po(joinpath(d, "fr", "LC_MESSAGES", "juango.po"), "Plural-Forms: nplurals=2; plural=(n > 1);", """
        msgid "this is to be translated"
        msgstr "il faut le traduire"

        msgctxt "month name"
        msgid "May"
        msgstr "mai"

        msgid "%s item"
        msgid_plural "%s items"
        msgstr[0] "%s élément"
        msgstr[1] "%s éléments"

        msgctxt "ctx"
        msgid "%s thing"
        msgid_plural "%s things"
        msgstr[0] "%s chose"
        msgstr[1] "%s choses"
        """)
    dxt_write_po(joinpath(d, "it", "LC_MESSAGES", "juango.po"), "Plural-Forms: nplurals=2; plural=(n != 1);",
                 "msgid \"Only in Italian\"\nmsgstr \"Solo in italiano\"\n")
    dxt_write_po(joinpath(d, "pl", "LC_MESSAGES", "juango.po"),
                 "Plural-Forms: nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
                 "msgid \"%s item\"\nmsgid_plural \"%s items\"\nmsgstr[0] \"%s element\"\nmsgstr[1] \"%s elementy\"\n")
    old = (get(settings, :LOCALE_PATHS, String[]), settings.LANGUAGE_CODE)
    configure!(LOCALE_PATHS = [d])
    Juango.reload_translations!()
    js, jc = Juango.JavaScriptCatalog(), Juango.JSONCatalog()
    req() = Request("GET", "/jsi18n/")
    cat(lang) = with_language(() -> JSON.parse(text(jc(req()))), lang)
    try
        c = cat("fr")                                                                   # test_jsoni18n
        @test c["catalog"]["month name\x04May"] == "mai" && c["catalog"]["this is to be translated"] == "il faut le traduire"
        @test c["plural"] == "(n > 1)" && c["catalog"]["%s item"] == ["%s élément", "%s éléments"]
        @test all(k -> haskey(c["formats"], k), Juango.FORMAT_SETTINGS) && c["formats"]["DECIMAL_SEPARATOR"] == ","   # test_get_formats
        @test c["formats"]["DATE_INPUT_FORMATS"] isa AbstractVector
        @test occursin("il faut le traduire", with_language(() -> text(js(req())), "fr"))   # test_jsi18n
        @test cat("pl")["catalog"]["%s item"] == ["%s element", "%s elementy", ""]       # (as many forms as the language has)
        @test isempty(cat("en")["catalog"])                                            # test_i18n_language_english_default (no catalogue)
        configure!(LANGUAGE_CODE = "fr")
        try
            @test !haskey(cat("en-us")["catalog"], "this is to be translated")          # test_jsi18n_with_missing_en_files / test_i18n_language_non_english_default
            ci = cat("it")                                                              # test_jsi18n_fallback_language
            @test ci["catalog"]["this is to be translated"] == "il faut le traduire" && ci["catalog"]["Only in Italian"] == "Solo in italiano"
            @test ci["catalog"]["%s item"] == ["%s élément", "%s éléments"]             # test_i18n_fallback_language_plural
            @test ci["plural"] == "(n != 1)"                                            # (the active language's rule)
            @test with_language(() -> gettext("this is to be translated"), "it") == "il faut le traduire"   # (gettext's fallback: LANGUAGE_CODE)
            @test with_language(() -> ngettext("%s item", "%s items", 2), "it") == "%s éléments"
            @test with_language(() -> gettext("this is to be translated"), "en-gb") == "this is to be translated"   # (not for English)
        finally
            configure!(LANGUAGE_CODE = old[2])
        end
        override_settings(USE_I18N = false) do                                          # test_jsi18n_USE_I18N_False
            s = with_language(() -> text(js(req())), "fr")
            @test !occursin("il faut le traduire", s) && occursin("juango.pluralidx", s)
        end
        if Sys.which("node") !== nothing                                                # JavaScriptI18nTests (Django: Selenium)
            dir = mktempdir()
            write(joinpath(dir, "catalog.js"), with_language(() -> text(js(req())), "fr"))
            write(joinpath(dir, "run.js"), """
                const vm = require("vm"), fs = require("fs");
                const ctx = {}; vm.createContext(ctx);
                vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), ctx);
                console.log(vm.runInContext(`JSON.stringify([gettext("this is to be translated"), gettext("untranslated"),
                    ngettext("%s item", "%s items", 0), ngettext("%s item", "%s items", 2), ngettext("a", "b", 5),
                    pgettext("month name", "May"), pgettext("other", "May"), npgettext("ctx", "%s thing", "%s things", 2),
                    interpolate(ngettext("%s item", "%s items", 3), [3]), interpolate("%(a)s and %(b)s", {a: 1, b: 2}, true),
                    get_format("DECIMAL_SEPARATOR"), get_format("NOPE"), pluralidx(0), pluralidx(2), gettext_noop("x"),
                    juango.gettext("this is to be translated")])`, ctx));
                """)
            r = JSON.parse(read(`node $(joinpath(dir, "run.js")) $(joinpath(dir, "catalog.js"))`, String))
            @test r[1] == "il faut le traduire" && r[2] == "untranslated"               # test_gettext
            @test r[3] == "%s élément" && r[4] == "%s éléments" && r[5] == "b"          # test_ngettext (French: 0 is singular)
            @test r[6] == "mai" && r[7] == "May" && r[8] == "%s choses"                 # test_pgettext, test_npgettext
            @test r[9] == "3 éléments" && r[10] == "1 and 2"                            # test_interpolate
            @test r[11] == "," && r[12] == "NOPE"                                       # test_get_format
            @test r[13] == 0 && r[14] == 1 && r[15] == "x" && r[16] == "il faut le traduire"   # test_pluralidx
        end
    finally
        configure!(LOCALE_PATHS = old[1], LANGUAGE_CODE = old[2])
        Juango.reload_translations!()
    end
end
