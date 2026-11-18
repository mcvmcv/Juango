# Django's forms tests, ported (#227): tests/forms_tests and the model form modules.
# julia --project=test test/django_forms.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# Django's f.clean(value), and the messages of the ValidationError it raises (assertRaisesMessage)
clean_errors(f, v, init...) = try
    Juango.clean(f, v, init...); nothing
catch e
    e isa Juango.ValidationError || rethrow()
    reduce(vcat, collect(values(e.errors)))
end
raises(f, v, msg) = (m = clean_errors(f, v); m !== nothing && any(x -> occursin(msg, x), m))
# assertWidgetRendersTo: the field alone in a form, named f; attributes compared in any order
function html_attrs(h)
    m = match(r"^<(\w+)((?:\s+[\w-]+(?:=\"[^\"]*\")?)*)\s*/?>(.*)$"s, strip(h))
    m === nothing && return h
    (m[1], Set(x.match for x in eachmatch(r"[\w-]+(?:=\"[^\"]*\")?", m[2])), m[3])
end
renders_to(f, html; kw...) = html_attrs(Juango.widget_html(Form([:f => f]; kw...)[:f])) == html_attrs(html)

@testset "django forms_tests: field_tests (CharField, IntegerField, FloatField, BooleanField)" begin
    # CharField
    f = CharField(max_length = nothing)
    @test Juango.clean(f, 1) == "1" && Juango.clean(f, "hello") == "hello"
    @test raises(f, nothing, "This field is required.") && raises(f, "", "This field is required.")
    @test Juango.clean(f, [1, 2, 3]) == "[1, 2, 3]"
    f = CharField(max_length = nothing, required = false)
    @test Juango.clean(f, 1) == "1" && Juango.clean(f, nothing) == "" && Juango.clean(f, "") == ""
    f = CharField(max_length = 10, required = false)
    @test Juango.clean(f, "1234567890") == "1234567890"
    @test raises(f, "1234567890a", "Ensure this value has at most 10 characters (it has 11).")
    f = CharField(max_length = nothing, min_length = 10, required = false)
    @test Juango.clean(f, "") == "" && Juango.clean(f, "1234567890a") == "1234567890a"
    @test raises(f, "12345", "Ensure this value has at least 10 characters (it has 5).")
    f = CharField(max_length = nothing, min_length = 10)
    @test raises(f, "", "This field is required.") && raises(f, "12345", "Ensure this value has at least 10 characters (it has 5).")
    # (Juango's CharField takes a max_length of 255 unless told otherwise: it is the model field too)
    @test CharField().max_length == 255
    # strip, and the empty value after stripping
    @test Juango.clean(CharField(), " 1") == "1" && Juango.clean(CharField(), "1 ") == "1"
    @test Juango.clean(CharField(strip = false), " 1") == " 1" && Juango.clean(CharField(strip = false), "1 ") == "1 "
    @test Juango.clean(CharField(required = false, empty_value = nothing), " ") === nothing
    @test Juango.clean(CharField(strip = false), " ") == " "
    @test renders_to(CharField(max_length = nothing, disabled = true), "<input type=\"text\" name=\"f\" id=\"id_f\" disabled required>")
    @test raises(CharField(), "\0something", "Null characters are not allowed.")
    # a disabled field keeps its initial value whatever is submitted
    df = Form([:name => CharField(disabled = true)]; data = Dict("name" => "changed"), initial = Dict(:name => "kept"))
    @test is_valid(df) && df.cleaned_data[:name] == "kept"

    # IntegerField
    f = IntegerField()
    @test renders_to(f, "<input type=\"number\" name=\"f\" id=\"id_f\" required>")
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, "1") === 1 && Juango.clean(f, "23") == 23 && Juango.clean(f, 42) == 42
    @test raises(f, "a", "Enter a whole number.") && raises(f, 3.14, "Enter a whole number.") && raises(f, "1a", "Enter a whole number.")
    @test Juango.clean(f, "1 ") == 1 && Juango.clean(f, " 1") == 1 && Juango.clean(f, " 1 ") == 1
    f = IntegerField(required = false)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing && Juango.clean(f, "1") === 1
    f = IntegerField(max_value = 10)
    @test renders_to(f, "<input max=\"10\" type=\"number\" name=\"f\" id=\"id_f\" required>")
    @test Juango.clean(f, 10) == 10 && Juango.clean(f, "10") == 10
    @test raises(f, 11, "Ensure this value is less than or equal to 10.") && raises(f, "11", "Ensure this value is less than or equal to 10.")
    f = IntegerField(min_value = 10)
    @test renders_to(f, "<input id=\"id_f\" type=\"number\" name=\"f\" min=\"10\" required>")
    @test raises(f, 1, "Ensure this value is greater than or equal to 10.") && Juango.clean(f, "11") == 11
    f = IntegerField(min_value = 10, max_value = 20)
    @test renders_to(f, "<input id=\"id_f\" max=\"20\" type=\"number\" name=\"f\" min=\"10\" required>")
    @test Juango.clean(f, 20) == 20 && raises(f, 21, "Ensure this value is less than or equal to 20.")
    f = IntegerField(step_size = 3)
    @test renders_to(f, "<input name=\"f\" step=\"3\" type=\"number\" id=\"id_f\" required>")
    @test raises(f, "10", "Ensure this value is a multiple of step size 3.") && Juango.clean(f, "12") == 12
    f = IntegerField(step_size = 3, min_value = -1)
    @test renders_to(f, "<input name=\"f\" min=\"-1\" step=\"3\" type=\"number\" id=\"id_f\" required>")
    @test raises(f, "9", "Ensure this value is a multiple of step size 3, starting from -1, e.g. -1, 2, 5, and so on.")
    @test Juango.clean(f, "2") == 2 && Juango.clean(f, "-1") == -1
    @test renders_to(IntegerField(localize = true), "<input id=\"id_f\" name=\"f\" type=\"text\" required>")
    # floats that are whole numbers, and other scripts' digits
    f = IntegerField()
    @test Juango.clean(f, 1.0) == 1 && Juango.clean(f, "1.0") == 1 && Juango.clean(f, " 1.0 ") == 1
    @test Juango.clean(f, "1.") == 1 && Juango.clean(f, " 1. ") == 1
    @test raises(f, "1.5", "Enter a whole number.") && raises(f, "…", "Enter a whole number.")
    @test Juango.clean(f, "５０") == 50
    # (Django's form IntegerField has no range; Juango's checks a 32-bit integer's, as it is also the model field)
    @test raises(f, "9223372036854775808", "")

    # FloatField
    f = FloatField()
    @test renders_to(f, "<input step=\"any\" type=\"number\" name=\"f\" id=\"id_f\" required>")
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, "1") === 1.0 && Juango.clean(f, "3.14") == 3.14 && Juango.clean(f, 3.14) == 3.14 && Juango.clean(f, 42) == 42.0
    @test raises(f, "a", "Enter a number.") && raises(f, "1.0a", "Enter a number.")
    @test Juango.clean(f, "1.0 ") == 1.0 && Juango.clean(f, " 1.0") == 1.0
    @test raises(f, "Infinity", "Enter a number.") && raises(f, "NaN", "Enter a number.") && raises(f, "-Inf", "Enter a number.")
    f = FloatField(required = false)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing && Juango.clean(f, "1") == 1.0
    f = FloatField(max_value = 1.5, min_value = 0.5)
    @test renders_to(f, "<input step=\"any\" name=\"f\" min=\"0.5\" max=\"1.5\" type=\"number\" id=\"id_f\" required>")
    @test raises(f, "1.6", "Ensure this value is less than or equal to 1.5.") && raises(f, "0.4", "Ensure this value is greater than or equal to 0.5.")
    @test Juango.clean(f, "1.5") == 1.5 && Juango.clean(f, "0.5") == 0.5
    f = FloatField(step_size = 0.02)
    @test renders_to(f, "<input name=\"f\" step=\"0.02\" type=\"number\" id=\"id_f\" required>")
    @test raises(f, "0.01", "Ensure this value is a multiple of step size 0.02.")
    @test Juango.clean(f, "2.34") == 2.34 && Juango.clean(f, "2.1") == 2.1 && Juango.clean(f, "-.5") == -0.5 && Juango.clean(f, "-1.26") == -1.26
    f = FloatField(step_size = 0.02, min_value = 0.01)
    @test raises(f, "0.02", "Ensure this value is a multiple of step size 0.02, starting from 0.01, e.g. 0.01, 0.03, 0.05, and so on.")
    @test Juango.clean(f, "2.33") == 2.33 && Juango.clean(f, "0.11") == 0.11
    @test renders_to(FloatField(localize = true), "<input id=\"id_f\" name=\"f\" type=\"text\" required>")

    # BooleanField: "false", "0" and empty are false, other values true
    f = BooleanField(required = false)
    @test Juango.clean(f, "") === false && Juango.clean(f, nothing) === false && Juango.clean(f, true) === true && Juango.clean(f, false) === false
    @test Juango.clean(f, 1) === true && Juango.clean(f, 0) === false && Juango.clean(f, "1") === true && Juango.clean(f, "0") === false
    @test Juango.clean(f, "Django rocks") === true && Juango.clean(f, "False") === false && Juango.clean(f, "false") === false &&
          Juango.clean(f, "FaLsE") === false
    # (a required BooleanField must be checked in Django; Juango's form BooleanField doesn't require it)
    @test_broken raises(BooleanField(), false, "This field is required.")
end

@choices DffFirstNames begin
    JOHN = "J", "John"
    PAUL = "P", "Paul"
end
@testset "django forms_tests: field_tests (ChoiceField, DecimalField)" begin
    f = ChoiceField([("1", "One"), ("2", "Two")])
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, 1) == "1" && Juango.clean(f, "1") == "1"
    @test raises(f, "3", "Select a valid choice. 3 is not one of the available choices.")
    f = ChoiceField([("1", "One"), ("2", "Two")]; required = false)
    @test Juango.clean(f, "") == "" && Juango.clean(f, nothing) == "" && Juango.clean(f, 1) == "1"
    @test raises(f, "3", "Select a valid choice. 3 is not one of the available choices.")
    f = ChoiceField([("J", "John"), ("P", "Paul")])
    @test Juango.clean(f, "J") == "J" && raises(f, "John", "Select a valid choice. John is not one of the available choices.")
    f = ChoiceField([("Numbers", (("1", "One"), ("2", "Two"))), ("Letters", (("3", "A"), ("4", "B"))), ("5", "Other")])
    @test Juango.clean(f, 1) == "1" && Juango.clean(f, "3") == "3" && Juango.clean(f, 5) == "5"
    @test raises(f, "6", "Select a valid choice. 6 is not one of the available choices.")
    @test Juango.clean(ChoiceField(() -> [("J", "John"), ("P", "Paul")]), "J") == "J"
    @test Juango.clean(ChoiceField(() -> Dict("J" => "John", "P" => "Paul")), "J") == "J"
    for f in (ChoiceField(Dict("J" => "John", "P" => "Paul")),)
        @test Juango.clean(f, "J") == "J"
    end
    for f in (ChoiceField(() -> Dict("Numbers" => Dict("1" => "One", "2" => "Two"), "Letters" => Dict("3" => "A", "4" => "B"))),
              ChoiceField(Dict("Numbers" => (("1", "One"), ("2", "Two")), "Letters" => (("3", "A"), ("4", "B")))),
              ChoiceField(Dict("Numbers" => Dict("1" => "One", "2" => "Two"), "Letters" => Dict("3" => "A", "4" => "B"))))
        @test all(i -> Juango.clean(f, i) == i, ("1", "2", "3", "4"))
    end
    # a function's choices are read each time the form is made
    chs = Any[("J", "John")]
    cf = ChoiceField(() -> chs)
    @test occursin("value=\"J\"", Juango.widget_html(Form([:c => cf])[:c]))
    chs = Any[("P", "Paul")]
    @test occursin("value=\"P\"", Juango.widget_html(Form([:c => cf])[:c])) && !occursin("value=\"J\"", Juango.widget_html(Form([:c => cf])[:c]))
    @test renders_to(ChoiceField([("J", "John"), ("P", "Paul")]; disabled = true),
                     "<select id=\"id_f\" name=\"f\" disabled><option value=\"J\">John</option><option value=\"P\">Paul</option></select>")
    f = ChoiceField(DffFirstNames)
    @test Juango.clean(f, "J") == "J" && raises(f, "3", "Select a valid choice. 3 is not one of the available choices.")

    # DecimalField
    D(s) = parse(Juango.Decimal, s)
    f = DecimalField(max_digits = 4, decimal_places = 2)
    @test renders_to(f, "<input id=\"id_f\" step=\"0.01\" type=\"number\" name=\"f\" required>")
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, "1") == D("1") && Juango.clean(f, "1") isa Juango.Decimal
    @test Juango.clean(f, "23") == D("23") && Juango.clean(f, "3.14") == D("3.14") && Juango.clean(f, 3.14) == D("3.14")
    @test Juango.clean(f, D("3.14")) == D("3.14") && Juango.clean(f, " 1.0 ") == D("1.0")
    @test raises(f, "123.45", "Ensure that there are no more than 4 digits in total.")
    @test raises(f, "1.234", "Ensure that there are no more than 2 decimal places.")
    @test raises(f, "123.4", "Ensure that there are no more than 2 digits before the decimal point.")
    @test Juango.clean(f, "-12.34") == D("-12.34") && raises(f, "-123.45", "Ensure that there are no more than 4 digits in total.")
    @test Juango.clean(f, "-.12") == D("-0.12") && Juango.clean(f, "-00.12") == D("-0.12") && Juango.clean(f, "-000.12") == D("-0.12")
    @test raises(f, "-000.123", "Ensure that there are no more than 2 decimal places.")
    @test raises(f, "-000.12345", "Ensure that there are no more than 4 digits in total.")
    f = DecimalField(max_value = 1, max_digits = 4, decimal_places = 2)
    for v in ("-NaN", "NaN", "+NaN", "-sNaN", "sNaN", "+sNaN", "-Inf", "Inf", "+Inf", "-Infinity", "Infinity", "+Infinity",
              "a", "łąść", "1.0a", "--0.12")
        @test raises(f, v, "Enter a number.")
    end
    f = DecimalField(max_digits = 4, decimal_places = 2, required = false)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing && Juango.clean(f, "1") == D("1")
    f = DecimalField(max_digits = 4, decimal_places = 2, max_value = D("1.5"), min_value = D("0.5"))
    @test renders_to(f, "<input step=\"0.01\" name=\"f\" min=\"0.5\" max=\"1.5\" type=\"number\" id=\"id_f\" required>")
    @test raises(f, "1.6", "Ensure this value is less than or equal to 1.5.") && raises(f, "0.4", "Ensure this value is greater than or equal to 0.5.")
    @test Juango.clean(f, "1.5") == D("1.5") && Juango.clean(f, ".5") == D("0.5") && Juango.clean(f, "00.50") == D("0.50")
    @test raises(DecimalField(decimal_places = 2), "0.00000001", "Ensure that there are no more than 2 decimal places.")
    f = DecimalField(max_digits = 3)
    @test Juango.clean(f, "0000000.10") == D("0.1") && Juango.clean(f, "000000.02") == D("0.02") && Juango.clean(f, ".002") == D("0.002")
    @test raises(f, "000000.0002", "Ensure that there are no more than 3 digits in total.")
    f = DecimalField(max_digits = 2, decimal_places = 2)
    @test Juango.clean(f, ".01") == D("0.01") && raises(f, "1.1", "Ensure that there are no more than 0 digits before the decimal point.")
    f = DecimalField(step_size = D("0.3"), min_value = D("-0.4"))
    @test renders_to(f, "<input name=\"f\" min=\"-0.4\" step=\"0.3\" type=\"number\" id=\"id_f\" required>")
    @test raises(f, "1", "Ensure this value is a multiple of step size 0.3, starting from -0.4, e.g. -0.4, -0.1, 0.2, and so on.")
    @test Juango.clean(f, "0.2") == D("0.2") && Juango.clean(f, 2) == D("2")
    f = DecimalField(max_digits = 4, decimal_places = 2)
    @test raises(f, "1E+2", "Ensure that there are no more")
    @test Juango.clean(f, "1E+1") == D("10") && Juango.clean(f, "1E-1") == D("0.1") && Juango.clean(f, "0.546e+2") == D("54.6")
    # the step the widget takes from decimal_places
    @test renders_to(DecimalField(max_digits = 10, decimal_places = 0), "<input step=\"1\" name=\"f\" type=\"number\" id=\"id_f\" required>")
    @test renders_to(DecimalField(max_digits = 19, decimal_places = 19), "<input step=\"1e-19\" name=\"f\" type=\"number\" id=\"id_f\" required>")
    @test renders_to(DecimalField(max_digits = 20), "<input step=\"any\" name=\"f\" type=\"number\" id=\"id_f\" required>")
    @test renders_to(DecimalField(localize = true), "<input id=\"id_f\" name=\"f\" type=\"text\" required>")
end

@testset "django forms_tests: field_tests (EmailField, RegexField, SlugField, UUIDField, TypedChoiceField)" begin
    # EmailField (Juango's takes the model field's max_length, 254; Django's form field 320)
    f = EmailField()
    @test renders_to(f, "<input type=\"email\" name=\"f\" id=\"id_f\" maxlength=\"254\" required>")
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, "person@example.com") == "person@example.com"
    @test raises(f, "foo", "Enter a valid email address.")
    @test Juango.clean(f, "local@domain.with.idn.xyzäöüßabc.part.com") == "local@domain.with.idn.xyzäöüßabc.part.com"
    @test raises(f, "viewx3dtextx26qx3d@yahoo.comx26latlngx3d15854521645943074058", "Enter a valid email address.")
    f = EmailField(required = false)
    @test Juango.clean(f, "") == "" && Juango.clean(f, nothing) == ""
    @test Juango.clean(f, "      example@example.com  \t   \t ") == "example@example.com"
    f = EmailField(min_length = 10, max_length = 15)
    @test renders_to(f, "<input id=\"id_f\" type=\"email\" name=\"f\" maxlength=\"15\" minlength=\"10\" required>")
    @test raises(f, "a@foo.com", "Ensure this value has at least 10 characters (it has 9).")
    @test Juango.clean(f, "alf@foo.com") == "alf@foo.com"
    @test raises(f, "alf123456788@foo.com", "Ensure this value has at most 15 characters (it has 20).")
    f = EmailField(required = false, empty_value = nothing)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing

    # RegexField: not stripped unless strip = true
    for f in (RegexField("^[0-9][A-F][0-9]\$"), RegexField(r"^[0-9][A-F][0-9]$"))
        @test Juango.clean(f, "2A2") == "2A2" && Juango.clean(f, "3F3") == "3F3"
        @test raises(f, "3G3", "Enter a valid value.") && raises(f, " 2A2", "Enter a valid value.") && raises(f, "2A2 ", "Enter a valid value.")
        @test raises(f, "", "This field is required.")
    end
    f = RegexField("^[0-9][A-F][0-9]\$"; required = false)
    @test Juango.clean(f, "2A2") == "2A2" && raises(f, "3G3", "Enter a valid value.") && Juango.clean(f, "") == ""
    f = RegexField("^[0-9]+\$"; min_length = 5, max_length = 10)
    @test raises(f, "123", "Ensure this value has at least 5 characters (it has 3).")
    @test clean_errors(f, "abc") == ["Ensure this value has at least 5 characters (it has 3).", "Enter a valid value."]
    @test Juango.clean(f, "12345") == "12345" && Juango.clean(f, "1234567890") == "1234567890"
    @test raises(f, "12345678901", "Ensure this value has at most 10 characters (it has 11).") && raises(f, "12345a", "Enter a valid value.")
    @test Juango.clean(RegexField(raw"^\w+$"), "éèøçÎÎ你好") == "éèøçÎÎ你好"
    f = RegexField("^[a-z]+\$"; strip = true)
    @test Juango.clean(f, " a") == "a" && Juango.clean(f, "a ") == "a"
    f = RegexField(""; required = false)
    @test Juango.clean(f, "") == "" && Juango.clean(f, nothing) == ""
    f = RegexField(""; empty_value = nothing, required = false)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing

    # SlugField
    @test Juango.clean(SlugField(), "    aa-bb-cc    ") == "aa-bb-cc"
    f = SlugField(allow_unicode = true)
    for (v, want) in (("a", "a"), ("1", "1"), ("a1", "a1"), ("你好", "你好"), ("  你-好  ", "你-好"), ("ıçğüş", "ıçğüş"), ("foo-ıç-bar", "foo-ıç-bar"))
        @test Juango.clean(f, v) == want
    end
    f = SlugField(required = false)
    @test Juango.clean(f, "") == "" && Juango.clean(f, nothing) == ""
    f = SlugField(required = false, empty_value = nothing)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing

    # UUIDField
    u = Juango.UUID("550e8400-e29b-41d4-a716-446655440000")
    @test Juango.clean(UUIDField(), "550e8400e29b41d4a716446655440000") == u
    @test Juango.clean(UUIDField(), "550e8400-e29b-41d4-a716-446655440000") == u
    @test Juango.clean(UUIDField(required = false), "") === nothing && Juango.clean(UUIDField(required = false), nothing) === nothing
    @test raises(UUIDField(), "550e8400", "Enter a valid UUID.")
    # (prepare_value: the form shows the hyphenated form)
    @test occursin("value=\"550e8400-e29b-41d4-a716-446655440000\"", Juango.widget_html(Form([:f => UUIDField()]; initial = Dict(:f => u))[:f]))

    # TypedChoiceField
    f = TypedChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> parse(Int, x))
    @test Juango.clean(f, "1") === 1 && raises(f, "2", "Select a valid choice. 2 is not one of the available choices.")
    @test Juango.clean(TypedChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> parse(Float64, x)), "1") === 1.0
    @test Juango.clean(TypedChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> !isempty(x)), "-1") === true
    f = TypedChoiceField([("A", "A"), ("B", "B")]; coerce = x -> parse(Int, x))
    @test raises(f, "B", "Select a valid choice. B is not one of the available choices.") && raises(f, "", "This field is required.")
    @test Juango.clean(TypedChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> parse(Int, x), required = false), "") == ""
    @test Juango.clean(TypedChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> parse(Int, x), required = false, empty_value = nothing), "") === nothing
    # a coerced value not among the choices is still accepted when the submitted one is (#21397)
    f = TypedChoiceField([(1, "1"), (2, "2")]; coerce = v -> parse(Juango.Decimal, "1.$v"))
    @test Juango.clean(f, "2") == parse(Juango.Decimal, "1.2")
    @test raises(f, "", "This field is required.") && raises(f, "3", "Select a valid choice. 3 is not one of the available choices.")
end

@form DffGetDate begin
    mydate = DateField(widget = SelectDateWidget())
end

@testset "django forms_tests: field_tests (DateField, TimeField, DurationField)" begin
    # DateField with a SelectDateWidget
    a = DffGetDate(Dict("mydate_month" => "4", "mydate_day" => "1", "mydate_year" => "2008"))
    @test is_valid(a) && a.cleaned_data[:mydate] == Date(2008, 4, 1)
    b = DffGetDate(Dict("mydate" => "2008-4-1"))
    @test is_valid(b) && b.cleaned_data[:mydate] == Date(2008, 4, 1)
    c = DffGetDate(Dict("mydate_month" => "2", "mydate_day" => "31", "mydate_year" => "2010"))
    @test !is_valid(c) && c.errors == Dict(:mydate => ["Enter a valid date."])
    d = DffGetDate(Dict("mydate_month" => "1", "mydate_day" => "1", "mydate_year" => "2010"))
    @test occursin("<label for=\"id_mydate_month\">", as_p(d).s)
    e = DffGetDate(Dict("mydate_month" => string(typemax(Int) + big(1)), "mydate_day" => "31", "mydate_year" => "2010"))
    @test !is_valid(e) && e.errors == Dict(:mydate => ["Enter a valid date."])
    b = DffGetDate(Dict("mydate_year" => "2008", "mydate_month" => "4", "mydate_day" => "1"); initial = Dict(:mydate => Date(2008, 4, 1)))
    @test !has_changed(b)
    b = DffGetDate(Dict("mydate_year" => "2008", "mydate_month" => "4", "mydate_day" => "2"); initial = Dict(:mydate => Date(2008, 4, 1)))
    @test has_changed(b)

    f = DateField()
    @test Juango.clean(f, Date(2006, 10, 25)) == Date(2006, 10, 25)
    @test Juango.clean(f, DateTime(2006, 10, 25, 14, 30)) == Date(2006, 10, 25)
    @test Juango.clean(f, DateTime(2006, 10, 25, 14, 30, 59, 200)) == Date(2006, 10, 25)
    for s in ("2006-10-25", "10/25/2006", "10/25/06", "Oct 25 2006", "October 25 2006", "October 25, 2006", "25 October 2006", "25 October, 2006")
        @test Juango.clean(f, s) == Date(2006, 10, 25)
    end
    for s in ("2006-4-31", "200a-10-25", "25/10/06", "0-0-0")
        @test raises(f, s, "Enter a valid date.")
    end
    @test raises(f, nothing, "This field is required.")
    f = DateField(required = false)
    @test Juango.clean(f, nothing) === nothing && Juango.clean(f, "") === nothing
    f = DateField(input_formats = ["%Y %m %d"])
    @test Juango.clean(f, Date(2006, 10, 25)) == Date(2006, 10, 25) && Juango.clean(f, DateTime(2006, 10, 25, 14, 30)) == Date(2006, 10, 25)
    @test Juango.clean(f, "2006 10 25") == Date(2006, 10, 25)
    @test raises(f, "2006-10-25", "Enter a valid date.") && raises(f, "10/25/2006", "Enter a valid date.") && raises(f, "10/25/06", "Enter a valid date.")

    # TimeField
    f = TimeField()
    @test Juango.clean(f, Time(14, 25)) == Time(14, 25) && Juango.clean(f, Time(14, 25, 59)) == Time(14, 25, 59)
    @test Juango.clean(f, "14:25") == Time(14, 25) && Juango.clean(f, "14:25:59") == Time(14, 25, 59)
    @test raises(f, "hello", "Enter a valid time.") && raises(f, "1:24 p.m.", "Enter a valid time.")
    f = TimeField(input_formats = ["%I:%M %p"])
    @test Juango.clean(f, Time(14, 25)) == Time(14, 25)
    @test Juango.clean(f, "4:25 AM") == Time(4, 25) && Juango.clean(f, "4:25 PM") == Time(16, 25)
    @test raises(f, "14:30:45", "Enter a valid time.")
    f = TimeField()
    @test Juango.clean(f, " 14:25 ") == Time(14, 25) && Juango.clean(f, " 14:25:59 ") == Time(14, 25, 59)
    @test raises(f, "   ", "This field is required.")      # (Django: "Enter a valid time."; stripped, it is empty)

    # DurationField
    f = DurationField()
    us(x) = Juango.duration_us(x)
    @test us(Juango.clean(f, "30")) == 30_000_000
    @test us(Juango.clean(f, "15:30")) == (15 * 60 + 30) * 1_000_000
    @test us(Juango.clean(f, "1:15:30")) == (3600 + 15 * 60 + 30) * 1_000_000
    @test us(Juango.clean(f, "1 1:15:30.3")) == (86400 + 3600 + 15 * 60 + 30) * 1_000_000 + 300_000
    @test us(Juango.clean(f, Dates.Second(10800))) == 10800 * 1_000_000
    @test raises(f, "", "This field is required.")
    @test raises(f, "not_a_time", "Enter a valid duration.") && raises(f, "P3(3D", "Enter a valid duration.")
    @test Juango.clean(DurationField(required = false), "") === nothing
    @test us(Juango.clean(f, 10800)) == 10800 * 1_000_000          # (an integer is seconds)
    @test renders_to(DurationField(default = Dates.Hour(1)), "<input id=\"id_f\" type=\"text\" name=\"f\" value=\"01:00:00\" required>")
end

@form DffHiddenNullBooleanForm begin
    hidden_nullbool1 = NullBooleanField(widget = :hidden, default = true)
    hidden_nullbool2 = NullBooleanField(widget = :hidden, default = false)
end

@testset "django forms_tests: field_tests (MultipleChoiceField, NullBooleanField, ComboField, JSONField)" begin
    # MultipleChoiceField
    f = MultipleChoiceField([("1", "One"), ("2", "Two")])
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, [1]) == ["1"] && Juango.clean(f, ["1"]) == ["1"] && Juango.clean(f, ["1", "2"]) == ["1", "2"]
    @test Juango.clean(f, [1, "2"]) == ["1", "2"] && Juango.clean(f, (1, "2")) == ["1", "2"]
    @test raises(f, "hello", "Enter a list of values.")
    @test raises(f, [], "This field is required.") && raises(f, (), "This field is required.")
    @test raises(f, ["3"], "Select a valid choice. 3 is not one of the available choices.")
    f = MultipleChoiceField([("1", "One"), ("2", "Two")]; required = false)
    @test Juango.clean(f, "") == [] && Juango.clean(f, nothing) == [] && Juango.clean(f, [1]) == ["1"]
    @test raises(f, "hello", "Enter a list of values.") && Juango.clean(f, []) == [] && Juango.clean(f, ()) == []
    f = MultipleChoiceField([("Numbers", (("1", "One"), ("2", "Two"))), ("Letters", (("3", "A"), ("4", "B"))), ("5", "Other")])
    @test Juango.clean(f, [1, 5]) == ["1", "5"] && Juango.clean(f, ["1", 5]) == ["1", "5"]
    @test raises(f, ["6"], "Select a valid choice. 6 is not one of the available choices.")
    @test raises(f, ["1", "6"], "Select a valid choice. 6 is not one of the available choices.")
    # duplicates are fine; the first invalid value is named
    f = MultipleChoiceField([("1", "One"), ("2", "Two"), ("3", "Three"), ("4", "Four"), ("5", "Five")])
    @test Juango.clean(f, ["4", "4", "5", "5"]) == ["4", "4", "5", "5"]
    @test raises(MultipleChoiceField([("1", "one"), ("2", "Two")]), ["invalid-one", "invalid-one", "invalid-two"], "invalid-one")

    # NullBooleanField: anything else is unknown
    f = NullBooleanField()
    @test Juango.clean(f, "") === nothing && Juango.clean(f, true) === true && Juango.clean(f, false) === false && Juango.clean(f, nothing) === nothing
    @test Juango.clean(f, "0") === false && Juango.clean(f, "1") === true
    # (Django: "2" and "3" are unknown; Juango also takes them as yes and no, the values NullBooleanSelect once sent)
    @test Juango.clean(f, "2") === true && Juango.clean(f, "3") === false
    @test Juango.clean(f, "hello") === nothing && Juango.clean(f, "true") === true && Juango.clean(f, "false") === false
    f = DffHiddenNullBooleanForm()
    @test occursin("<input type=\"hidden\" name=\"hidden_nullbool1\" value=\"True\" id=\"id_hidden_nullbool1\">", as_p(f).s) ||
          occursin("<input type=\"hidden\" name=\"hidden_nullbool1\" id=\"id_hidden_nullbool1\" value=\"True\">", as_p(f).s)
    f = DffHiddenNullBooleanForm(Dict("hidden_nullbool1" => "True", "hidden_nullbool2" => "False"))
    @test is_valid(f) && f.cleaned_data[:hidden_nullbool1] === true && f.cleaned_data[:hidden_nullbool2] === false
    nb = [("1", "Yes"), ("0", "No"), ("", "Unknown")]
    f = Form([:nullbool0 => NullBooleanField(widget = :radio), :nullbool1 => NullBooleanField(widget = :radio),
              :nullbool2 => NullBooleanField(widget = :radio)]; data = Dict("nullbool0" => "1", "nullbool1" => "0", "nullbool2" => ""))
    @test is_valid(f) && f.cleaned_data[:nullbool0] === true && f.cleaned_data[:nullbool1] === false && f.cleaned_data[:nullbool2] === nothing

    # ComboField
    f = ComboField([CharField(max_length = 20), EmailField()])
    @test Juango.clean(f, "test@example.com") == "test@example.com"
    @test raises(f, "longemailaddress@example.com", "Ensure this value has at most 20 characters (it has 28).")
    @test raises(f, "not an email", "Enter a valid email address.")
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    f = ComboField([CharField(max_length = 20), EmailField()]; required = false)
    @test Juango.clean(f, "test@example.com") == "test@example.com" && raises(f, "not an email", "Enter a valid email address.")
    @test Juango.clean(f, "") == "" && Juango.clean(f, nothing) == ""

    # JSONField
    @test Juango.clean(JSONField(), "{\"a\": \"b\"}") == Dict("a" => "b")
    @test Juango.clean(JSONField(required = false), "") === nothing && Juango.clean(JSONField(required = false), nothing) === nothing
    @test raises(JSONField(), "{some badly formed: json}", "Enter a valid JSON.")
    # a cleaned value cleans to itself
    f = JSONField(required = false)
    # (not "\"foo\"": its cleaned value, a string, is read as JSON text again; Django marks it as decoded)
    for js in ("[\"a\", \"b\", \"c\"]", "{\"a\": 1, \"b\": 2}", "1", "1.5", "true", "false")
        val = Juango.clean(f, js)
        @test Juango.clean(f, val) == val
    end
    @test occursin("<textarea", Juango.widget_html(Form([:f => JSONField()])[:f]))
    # a disabled field shows its initial value, not the submitted one
    jf = Form([:json_field => JSONField(disabled = true)]; data = Dict("json_field" => "[\"bar\"]"), initial = Dict(:json_field => ["foo"]))
    @test occursin("[&quot;foo&quot;]</textarea>", as_p(jf).s)
end

@testset "django forms_tests: field_tests (URLField, GenericIPAddressField)" begin
    # URLField (Juango's takes the model field's max_length, 200)
    @test renders_to(URLField(max_length = nothing), "<input type=\"url\" name=\"f\" id=\"id_f\" required>")
    f = URLField(min_length = 15, max_length = 20)
    @test Juango.clean(f, "http://example.com") == "http://example.com"
    @test renders_to(f, "<input id=\"id_f\" type=\"url\" name=\"f\" maxlength=\"20\" minlength=\"15\" required>")
    @test raises(f, "http://f.com", "Ensure this value has at least 15 characters (it has 12).")
    @test raises(f, "http://abcdefghijklmnopqrstuvwxyz.com", "Ensure this value has at most 20 characters (it has 37).")
    f = URLField(required = false, max_length = nothing)
    for (url, want) in (
            ("http://localhost", "http://localhost"), ("http://example.com", "http://example.com"),
            ("http://example.com/test", "http://example.com/test"), ("http://example.com.", "http://example.com."),
            ("http://www.example.com", "http://www.example.com"), ("http://www.example.com:8000/test", "http://www.example.com:8000/test"),
            ("http://example.com?some_param=some_value", "http://example.com?some_param=some_value"),
            ("valid-with-hyphens.com", "https://valid-with-hyphens.com"), ("subdomain.domain.com", "https://subdomain.domain.com"),
            ("http://200.8.9.10", "http://200.8.9.10"), ("http://200.8.9.10:8000/test", "http://200.8.9.10:8000/test"),
            ("http://valid-----hyphens.com", "http://valid-----hyphens.com"),
            ("http://some.idn.xyzäöüßabc.domain.com:123/blah", "http://some.idn.xyzäöüßabc.domain.com:123/blah"),
            ("www.example.com/s/http://code.djangoproject.com/ticket/13804", "https://www.example.com/s/http://code.djangoproject.com/ticket/13804"),
            ("http://example.com/     ", "http://example.com/"), ("http://עברית.idn.icann.org/", "http://עברית.idn.icann.org/"),
            ("http://sãopaulo.com/", "http://sãopaulo.com/"), ("http://sãopaulo.com.br/", "http://sãopaulo.com.br/"),
            ("http://пример.испытание/", "http://пример.испытание/"), ("http://مثال.إختبار/", "http://مثال.إختبار/"),
            ("http://例子.测试/", "http://例子.测试/"), ("http://例子.測試/", "http://例子.測試/"),
            ("http://उदाहरण.परीक्षा/", "http://उदाहरण.परीक्षा/"), ("http://例え.テスト/", "http://例え.テスト/"),
            ("http://مثال.آزمایشی/", "http://مثال.آزمایشی/"), ("http://실례.테스트/", "http://실례.테스트/"),
            ("http://العربية.idn.icann.org/", "http://العربية.idn.icann.org/"),
            ("http://[12:34::3a53]/", "http://[12:34::3a53]/"), ("http://[a34:9238::]:8080/", "http://[a34:9238::]:8080/"),
            ("[12:34::3a53]/", "https://[12:34::3a53]/"), ("ñandú.es:8080/", "https://ñandú.es:8080/"),
            ("//example.com", "https://example.com"), ("//example.com/path", "https://example.com/path"),
            ("\t\n//example.com  \n\t\n", "https://example.com"), ("\t\nhttp://example.com  \n\t\n", "http://example.com"))
        @test (r = try Juango.clean(f, url) catch e; e end) == want
    end
    f = URLField(max_length = nothing)
    for v in ("foo", "com.", ".", "http://", "http://example", "http://example.", "http://.com", "http://invalid-.com",
              "http://-invalid.com", "http://inv-.alid-.com", "http://inv-.-alid.com", "[a", "http://[a", 23,
              "http://" * "X"^60, "http://" * "X"^200, "////]@N.AN", "#@A.bO", "http://" * "¾"^200, "¾:example.com",
              "1http://example.com", "://example.com", ":example.com")
        @test raises(f, v, "Enter a valid URL.")
    end
    @test raises(URLField(), nothing, "This field is required.") && raises(URLField(), "", "This field is required.")
    @test Juango.clean(URLField(required = false), nothing) == "" && Juango.clean(URLField(required = false), "") == ""
    f = URLField(required = false, empty_value = nothing)
    @test Juango.clean(f, "") === nothing && Juango.clean(f, nothing) === nothing

    # GenericIPAddressField
    @test_throws ArgumentError GenericIPAddressField(protocol = "hamster")
    @test_throws ArgumentError GenericIPAddressField(protocol = "ipv4", unpack_ipv4 = true)
    f = GenericIPAddressField()
    @test raises(f, "", "This field is required.") && raises(f, nothing, "This field is required.")
    @test Juango.clean(f, " 127.0.0.1 ") == "127.0.0.1"
    for v in ("foo", "127.0.0.", "1.2.3.4.5", "256.125.1.5")
        @test raises(f, v, "Enter a valid IPv4 or IPv6 address.")
    end
    @test Juango.clean(f, " fe80::223:6cff:fe8a:2e8a ") == "fe80::223:6cff:fe8a:2e8a"
    @test Juango.clean(f, " 2a02::223:6cff:fe8a:2e8a ") == "2a02::223:6cff:fe8a:2e8a"
    for v in ("12345:2:3:4", "1::2:3::4", "foo::223:6cff:fe8a:2e8a", "1::2:3:4:5:6:7:8", "1:2")
        @test raises(f, v, "This is not a valid IPv6 address.")
    end
    f = GenericIPAddressField(protocol = "IPv4")
    @test raises(f, "", "This field is required.") && Juango.clean(f, " 127.0.0.1 ") == "127.0.0.1"
    for v in ("foo", "127.0.0.", "1.2.3.4.5", "256.125.1.5", "fe80::223:6cff:fe8a:2e8a", "2a02::223:6cff:fe8a:2e8a")
        @test raises(f, v, "Enter a valid IPv4 address.")
    end
    f = GenericIPAddressField(protocol = "IPv6")
    @test raises(f, "", "This field is required.")
    for v in ("127.0.0.1", "foo", "127.0.0.", "1.2.3.4.5", "256.125.1.5")
        @test raises(f, v, "Enter a valid IPv6 address.")
    end
    @test Juango.clean(f, " fe80::223:6cff:fe8a:2e8a ") == "fe80::223:6cff:fe8a:2e8a"
    for v in ("12345:2:3:4", "1::2:3::4", "foo::223:6cff:fe8a:2e8a", "1::2:3:4:5:6:7:8", "1:2")
        @test raises(f, v, "This is not a valid IPv6 address.")
    end
    addr = "0000:0000:0000:0000:0000:ffff:192.168.100.228"
    @test Juango.clean(GenericIPAddressField(max_length = length(addr)), addr) isa AbstractString
end

@testset "django forms_tests: field_tests (SplitDateTimeField, TypedMultipleChoiceField, DateTimeField)" begin
    # SplitDateTimeField
    f = SplitDateTimeField()
    @test Juango.clean(f, [Date(2006, 1, 10), Time(7, 30)]) == DateTime(2006, 1, 10, 7, 30)
    @test raises(f, nothing, "This field is required.") && raises(f, "", "This field is required.")
    @test raises(f, "hello", "Enter a list of values.")
    @test clean_errors(f, ["hello", "there"]) == ["Enter a valid date.", "Enter a valid time."]
    @test clean_errors(f, ["2006-01-10", "there"]) == ["Enter a valid time."]
    @test clean_errors(f, ["hello", "07:30"]) == ["Enter a valid date."]
    f = SplitDateTimeField(required = false)
    @test Juango.clean(f, [Date(2006, 1, 10), Time(7, 30)]) == DateTime(2006, 1, 10, 7, 30)
    @test Juango.clean(f, ["2006-01-10", "07:30"]) == DateTime(2006, 1, 10, 7, 30)
    @test Juango.clean(f, nothing) === nothing && Juango.clean(f, "") === nothing
    @test Juango.clean(f, [""]) === nothing && Juango.clean(f, ["", ""]) === nothing
    @test raises(f, "hello", "Enter a list of values.")
    @test clean_errors(f, ["hello", "there"]) == ["Enter a valid date.", "Enter a valid time."]
    @test clean_errors(f, ["2006-01-10", ""]) == ["Enter a valid time."]
    @test clean_errors(f, ["2006-01-10"]) == ["Enter a valid time."]
    @test clean_errors(f, ["", "07:30"]) == ["Enter a valid date."]
    # (Juango's inputs are a date and a time input; Django's two text inputs)
    h = as_table(Form([:datetime => SplitDateTimeField()])).s
    @test occursin("name=\"datetime_0\"", h) && occursin("name=\"datetime_1\"", h) && occursin("id=\"id_datetime_0\"", h)

    # TypedMultipleChoiceField
    pint(x) = parse(Int, x)
    f = TypedMultipleChoiceField([(1, "+1"), (-1, "-1")]; coerce = pint)
    @test Juango.clean(f, ["1"]) == [1] && raises(f, ["2"], "Select a valid choice. 2 is not one of the available choices.")
    @test Juango.clean(TypedMultipleChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> parse(Float64, x)), ["1"]) == [1.0]
    @test Juango.clean(TypedMultipleChoiceField([(1, "+1"), (-1, "-1")]; coerce = x -> !isempty(x)), ["-1"]) == [true]
    @test Juango.clean(f, ["1", "-1"]) == [1, -1] && raises(f, ["1", "2"], "Select a valid choice. 2 is not one of the available choices.")
    f = TypedMultipleChoiceField([("A", "A"), ("B", "B")]; coerce = pint)
    @test raises(f, ["B"], "Select a valid choice. B is not one of the available choices.") && raises(f, [], "This field is required.")
    @test Juango.clean(TypedMultipleChoiceField([(1, "+1"), (-1, "-1")]; coerce = pint, required = false), []) == []
    f = TypedMultipleChoiceField([(1, "1"), (2, "2")]; coerce = v -> parse(Juango.Decimal, "1.$v"))
    @test Juango.clean(f, ["2"]) == [parse(Juango.Decimal, "1.2")]
    @test raises(f, [], "This field is required.") && raises(f, ["3"], "Select a valid choice. 3 is not one of the available choices.")

    # DateTimeField (naive: the tests' settings have USE_TZ off)
    f = DateTimeField()
    for (v, want) in ((Date(2006, 10, 25), DateTime(2006, 10, 25)), (DateTime(2006, 10, 25, 14, 30), DateTime(2006, 10, 25, 14, 30)),
                      ("2006-10-25 14:30:45", DateTime(2006, 10, 25, 14, 30, 45)), ("2006-10-25 14:30:00", DateTime(2006, 10, 25, 14, 30)),
                      ("2006-10-25 14:30", DateTime(2006, 10, 25, 14, 30)), ("2006-10-25", DateTime(2006, 10, 25)),
                      ("10/25/2006 14:30:45", DateTime(2006, 10, 25, 14, 30, 45)), ("10/25/2006 14:30", DateTime(2006, 10, 25, 14, 30)),
                      ("10/25/2006", DateTime(2006, 10, 25)), ("10/25/06 14:30:45", DateTime(2006, 10, 25, 14, 30, 45)),
                      ("10/25/06 14:30", DateTime(2006, 10, 25, 14, 30)), ("10/25/06", DateTime(2006, 10, 25)),
                      ("2014-09-23T22:34:41", DateTime(2014, 9, 23, 22, 34, 41)), ("2014-09-23T22:34", DateTime(2014, 9, 23, 22, 34)),
                      ("2014-09-23", DateTime(2014, 9, 23)), (" 2006-10-25   14:30:45 ", DateTime(2006, 10, 25, 14, 30, 45)),
                      (" 2006-10-25 ", DateTime(2006, 10, 25)), (" 10/25/2006 14:30:45 ", DateTime(2006, 10, 25, 14, 30, 45)),
                      (" 10/25/06 ", DateTime(2006, 10, 25)))
        @test (r = try Juango.clean(f, v) catch e; e end) == want
    end
    # (milliseconds: Julia's DateTime keeps no finer part)
    @test Juango.clean(f, "2006-10-25 14:30:45.000200") == DateTime(2006, 10, 25, 14, 30, 45)
    @test Juango.clean(f, "2014-09-23T22:34:41.614804") == DateTime(2014, 9, 23, 22, 34, 41, 614)
    for v in ("hello", "2006-10-25 4:30 p.m.", "2014-09-23T28:23")
        @test raises(f, v, "Enter a valid date/time.")
    end
    f = DateTimeField(input_formats = ["%Y %m %d %I:%M %p"])
    @test raises(f, "2006.10.25 14:30:45", "Enter a valid date/time.")
    @test Juango.clean(f, Date(2006, 10, 25)) == DateTime(2006, 10, 25) && Juango.clean(f, DateTime(2006, 10, 25, 14, 30)) == DateTime(2006, 10, 25, 14, 30)
    @test Juango.clean(f, "2006 10 25 2:30 PM") == DateTime(2006, 10, 25, 14, 30)
    # (ISO 8601 is always taken, as Django's DateTimeField)
    @test Juango.clean(f, "2006-10-25 14:30:45") == DateTime(2006, 10, 25, 14, 30, 45)
    @test Juango.clean(DateTimeField(input_formats = ["%Y.%m.%d %H:%M:%S.%f"]), "2006.10.25 14:30:45.0002") == DateTime(2006, 10, 25, 14, 30, 45)
end

@testset "django forms_tests: field_tests (FileField)" begin
    f = FileField()
    @test raises(f, "", "This field is required.") && clean_errors(f, "", "") == ["This field is required."]
    @test Juango.clean(f, "", "files/test1.pdf") == "files/test1.pdf"
    @test raises(f, nothing, "This field is required.") && clean_errors(f, nothing, "") == ["This field is required."]
    @test Juango.clean(f, nothing, "files/test2.pdf") == "files/test2.pdf"
    nofile = "No file was submitted. Check the encoding type on the form."
    @test raises(f, UploadedFile("", ""), nofile) && clean_errors(f, UploadedFile("", ""), "") == [nofile]
    @test raises(f, "some content that is not a file", nofile)
    @test raises(f, UploadedFile("name", ""), "The submitted file is empty.")
    @test Juango.clean(f, UploadedFile("name", "Some File Content")) isa UploadedFile
    @test Juango.clean(f, UploadedFile("我隻氣墊船裝滿晒鱔.txt", "मेरी मँडराने वाली नाव सर्पमीनों से भरी ह")) isa UploadedFile
    @test Juango.clean(f, UploadedFile("name", "Some File Content"), "files/test4.pdf") isa UploadedFile
    f = FileField(max_length = 5)
    @test raises(f, UploadedFile("test_maxlength.txt", "hello world"), "Ensure this filename has at most 5 characters (it has 18).")
    @test Juango.clean(f, "", "files/test1.pdf") == "files/test1.pdf" && Juango.clean(f, nothing, "files/test2.pdf") == "files/test2.pdf"
    @test Juango.clean(f, UploadedFile("name", "Some File Content")) isa UploadedFile
    # (Django's allow_empty_file = true; Juango's FileField has no such option)
    @test_broken (try Juango.clean(FileField(), UploadedFile("name", "")) isa UploadedFile catch; false end)
    # MultipleFileField
    files = [UploadedFile("name1", "Content 1"), UploadedFile("name2", "Content 2")]
    @test [u.name for u in Juango.clean(MultipleFileField(), files)] == ["name1", "name2"]
end

const DFF_BEATLES = [("J", "John"), ("P", "Paul"), ("G", "George"), ("R", "Ringo")]
dff_complex(; kw...) = MultiValueField([CharField(max_length = nothing), MultipleChoiceField(DFF_BEATLES), SplitDateTimeField()];
    compress = vs -> isempty(vs) ? nothing : "$(vs[1]),$(join(vs[2])),$(Dates.format(vs[3], "yyyy-mm-dd HH:MM:SS"))",
    decompress = v -> v === nothing ? [nothing, nothing, nothing] :
                      (p = split(v, ","); [p[1], [string(c) for c in p[2]], DateTime(p[3], dateformat"yyyy-mm-dd HH:MM:SS")]), kw...)

@testset "django forms_tests: field_tests (MultiValueField)" begin
    f = dff_complex()
    @test Juango.clean(f, ["some text", ["J", "P"], ["2007-04-25", "6:24:00"]]) == "some text,JP,2007-04-25 06:24:00"
    @test raises(f, ["some text", ["X"], ["2007-04-25", "6:24:00"]], "Select a valid choice. X is not one of the available choices.")
    # a part left out is empty: a required field's "This field is required."
    @test clean_errors(f, ["some text", ["JP"]]) == ["This field is required."]
    # a part not required may be left empty when not every field is required (require_all_fields = false)
    pr = MultiValueField([CharField(max_length = nothing), CharField(max_length = nothing, required = false)];
                         compress = vs -> join(something.(vs, ""), ","), decompress = v -> split(v, ","), require_all_fields = false)
    @test Juango.clean(pr, ["Hello", ""]) == "Hello,"
    @test clean_errors(pr, ["", "World"]) == ["Enter a complete value."]
    pf = Form([:f => pr]; data = Dict("f_0" => "Hello", "f_1" => ""))
    @test is_valid(pf) && pf.cleaned_data[:f] == "Hello,"
    pf = Form([:f => pr]; data = Dict("f_0" => "", "f_1" => ""))
    @test !is_valid(pf) && pf.errors[:f] == ["This field is required."]
    # the form: has_changed compares the parts with the initial value's
    g(data; initial = nothing) = Form([:field1 => dff_complex()]; data = data,
                                      initial = initial === nothing ? Dict{Symbol,Any}() : Dict(:field1 => initial))
    same = Dict("field1_0" => "some text", "field1_1" => ["J", "P"], "field1_2_0" => "2007-04-25", "field1_2_1" => "06:24:00")
    gs = g(same)
    @test is_valid(gs) && gs.cleaned_data[:field1] == "some text,JP,2007-04-25 06:24:00"
    @test !has_changed(g(same; initial = "some text,JP,2007-04-25 06:24:00"))
    @test has_changed(g(merge(same, Dict("field1_0" => "other text")); initial = "some text,JP,2007-04-25 06:24:00"))
    @test has_changed(g(merge(same, Dict("field1_2_0" => "2009-04-25", "field1_2_1" => "11:44:00")); initial = "some text,JP,2007-04-25 06:24:00"))
    @test has_changed(g(same))
end
