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

# ---- Django's forms_tests/tests/test_forms.py (FormsTestCase). Juango renders dates as type="date" inputs
# (Django: type="text"); expectations say so where it shows.

# assertHTMLEqual: tags with their attributes in any order, text with whitespace collapsed
function html_tokens(h)
    out = Any[]
    for m in eachmatch(r"<[^>]+>|[^<]+", String(h))
        t = m.match
        if startswith(t, "<")
            mm = match(r"^<(/?)([\w-]+)(.*?)/?>$"s, t)
            mm === nothing && (push!(out, t); continue)
            attrs = Set(x.match for x in eachmatch(r"[\w:-]+(?:=\"[^\"]*\")?", mm[3]))
            push!(out, (mm[1] * lowercase(mm[2]), attrs))
        else
            s = strip(replace(t, r"\s+" => " "))
            isempty(s) || push!(out, s)
        end
    end
    out
end
html_eq(a, b) = html_tokens(string(a)) == html_tokens(string(b))
w(bf) = Juango.widget_html(bf)

@form DftPerson begin
    first_name = CharField(max_length = nothing)
    last_name = CharField(max_length = nothing)
    birthday = DateField()
end
@form DftPersonNew begin
    first_name = CharField(max_length = nothing, widget = Widget(attrs = Dict("id" => "first_name_id")))
    last_name = CharField(max_length = nothing)
    birthday = DateField()
end

@testset "django forms_tests: test_forms (bound and unbound forms, rendering, auto_id)" begin
    p = DftPerson(Dict("first_name" => "John", "last_name" => "Lennon", "birthday" => "1940-10-9"))
    @test p.data !== nothing && is_valid(p) && isempty(p.errors)
    @test p.cleaned_data[:first_name] == "John" && p.cleaned_data[:last_name] == "Lennon" && p.cleaned_data[:birthday] == Date(1940, 10, 9)
    @test html_eq(w(p[:first_name]), "<input type=\"text\" name=\"first_name\" value=\"John\" id=\"id_first_name\" required>")
    @test html_eq(w(p[:birthday]), "<input type=\"date\" name=\"birthday\" value=\"1940-10-9\" id=\"id_birthday\" required>")
    e = try p[:nonexistentfield] catch e; e end
    @test e isa KeyError && e.key == "Key 'nonexistentfield' not found in 'DftPerson'. Choices are: birthday, first_name, last_name."
    @test [[bf.label, bf.data] for bf in p] == [["First name", "John"], ["Last name", "Lennon"], ["Birthday", "1940-10-9"]]
    @test html_eq(as_div(p),
        "<div><label for=\"id_first_name\">First name:</label><input type=\"text\" name=\"first_name\" value=\"John\" required id=\"id_first_name\"></div>" *
        "<div><label for=\"id_last_name\">Last name:</label><input type=\"text\" name=\"last_name\" value=\"Lennon\" required id=\"id_last_name\"></div>" *
        "<div><label for=\"id_birthday\">Birthday:</label><input type=\"date\" name=\"birthday\" value=\"1940-10-9\" required id=\"id_birthday\"></div>")

    # an empty dict is bound: every field is required
    p = DftPerson(Dict{String,Any}())
    @test p.data !== nothing && !is_valid(p) && isempty(p.cleaned_data)
    @test p.errors[:first_name] == ["This field is required."] && p.errors[:birthday] == ["This field is required."]
    err(n) = "<ul class=\"errorlist\" id=\"id_$(n)_error\"><li>This field is required.</li></ul>"
    inp(n, t = "text") = "<input type=\"$t\" name=\"$n\" aria-invalid=\"true\" required id=\"id_$n\" aria-describedby=\"id_$(n)_error\">"
    lab(n, l) = "<label for=\"id_$n\">$l:</label>"
    fs = [("first_name", "First name", "text"), ("last_name", "Last name", "text"), ("birthday", "Birthday", "date")]
    @test html_eq(as_div(p), join(["<div>" * lab(n, l) * err(n) * inp(n, t) * "</div>" for (n, l, t) in fs]))
    @test html_eq(as_table(p), join(["<tr><th>" * lab(n, l) * "</th><td>" * err(n) * inp(n, t) * "</td></tr>" for (n, l, t) in fs]))
    @test html_eq(as_ul(p), join(["<li>" * err(n) * lab(n, l) * inp(n, t) * "</li>" for (n, l, t) in fs]))
    @test html_eq(as_p(p), join([err(n) * "<p>" * lab(n, l) * inp(n, t) * "</p>" for (n, l, t) in fs]))

    # unbound: no errors, not valid
    p = DftPerson()
    @test p.data === nothing && isempty(p.errors) && !is_valid(p)
    plain(n, t = "text") = "<input type=\"$t\" name=\"$n\" id=\"id_$n\" required>"
    @test html_eq(as_div(p), join(["<div>" * lab(n, l) * plain(n, t) * "</div>" for (n, l, t) in fs]))
    @test html_eq(as_table(p), join(["<tr><th>" * lab(n, l) * "</th><td>" * plain(n, t) * "</td></tr>" for (n, l, t) in fs]))
    @test html_eq(as_ul(p), join(["<li>" * lab(n, l) * plain(n, t) * "</li>" for (n, l, t) in fs]))
    @test html_eq(as_p(p), join(["<p>" * lab(n, l) * plain(n, t) * "</p>" for (n, l, t) in fs]))

    # unicode values; a partly filled form
    p = DftPerson(Dict("first_name" => "John", "last_name" => "ŠĐĆŽćžšđ", "birthday" => "1940-10-9"))
    @test occursin("value=\"ŠĐĆŽćžšđ\"", as_table(p).s)
    p = DftPerson(Dict("last_name" => "Lennon"))
    @test !is_valid(p) && p.errors == Dict(:birthday => ["This field is required."], :first_name => ["This field is required."])
    @test p.cleaned_data == Dict(:last_name => "Lennon") && p[:first_name].errors == ["This field is required."]
    @test html_eq(p[:first_name].errors_html, "<ul class=\"errorlist\" id=\"id_first_name_error\"><li>This field is required.</li></ul>")

    # cleaned_data has only the form's fields; optional ones are there, empty
    p = DftPerson(Dict("first_name" => "John", "last_name" => "Lennon", "birthday" => "1940-10-9", "extra1" => "hello", "extra2" => "hello"))
    @test is_valid(p) && Set(keys(p.cleaned_data)) == Set([:first_name, :last_name, :birthday])
    f = Form([:first_name => CharField(max_length = nothing), :last_name => CharField(max_length = nothing),
              :nick_name => CharField(max_length = nothing, required = false)]; data = Dict("first_name" => "John", "last_name" => "Lennon"))
    @test is_valid(f) && f.cleaned_data[:nick_name] == ""
    f = Form([:first_name => CharField(max_length = nothing), :last_name => CharField(max_length = nothing),
              :birth_date => DateField(required = false)]; data = Dict("first_name" => "John", "last_name" => "Lennon"))
    @test is_valid(f) && f.cleaned_data[:birth_date] === nothing

    # auto_id: a format, true (the name), false (no ids, no <label>)
    p = DftPerson(; auto_id = "%s_id")
    @test html_eq(as_ul(p), join(["<li><label for=\"$(n)_id\">$l:</label><input type=\"$t\" name=\"$n\" id=\"$(n)_id\" required></li>" for (n, l, t) in fs]))
    p = DftPerson(; auto_id = true)
    @test html_eq(as_ul(p), join(["<li><label for=\"$n\">$l:</label><input type=\"$t\" name=\"$n\" id=\"$n\" required></li>" for (n, l, t) in fs]))
    p = DftPerson(; auto_id = false)
    @test html_eq(as_ul(p), join(["<li>$l: <input type=\"$t\" name=\"$n\" required></li>" for (n, l, t) in fs]))
    # an id on the widget: used whatever auto_id says
    p = DftPersonNew(; auto_id = false)
    @test html_eq(as_ul(p), "<li><label for=\"first_name_id\">First name:</label><input type=\"text\" id=\"first_name_id\" name=\"first_name\" required></li>" *
                            "<li>Last name: <input type=\"text\" name=\"last_name\" required></li><li>Birthday: <input type=\"date\" name=\"birthday\" required></li>")
    p = DftPersonNew(; auto_id = true)
    @test html_eq(as_ul(p), "<li><label for=\"first_name_id\">First name:</label><input type=\"text\" id=\"first_name_id\" name=\"first_name\" required></li>" *
                            "<li><label for=\"last_name\">Last name:</label><input type=\"text\" name=\"last_name\" id=\"last_name\" required></li>" *
                            "<li><label for=\"birthday\">Birthday:</label><input type=\"date\" name=\"birthday\" id=\"birthday\" required></li>")
end

@testset "django forms_tests: test_forms (help text, hidden fields)" begin
    reg(; data = nothing, kw...) = Form([:username => CharField(max_length = 10, help_text = "e.g., user@example.com"),
                                         :password => CharField(max_length = nothing, widget = :password, help_text = "Wählen Sie mit Bedacht.")];
                                        data = data, kw...)
    p = reg(; auto_id = false)
    @test html_eq(as_ul(p), "<li>Username: <input type=\"text\" name=\"username\" maxlength=\"10\" required><span class=\"helptext\">e.g., user@example.com</span></li>" *
                            "<li>Password: <input type=\"password\" name=\"password\" required><span class=\"helptext\">Wählen Sie mit Bedacht.</span></li>")
    @test html_eq(as_p(p), "<p>Username: <input type=\"text\" name=\"username\" maxlength=\"10\" required><span class=\"helptext\">e.g., user@example.com</span></p>" *
                           "<p>Password: <input type=\"password\" name=\"password\" required><span class=\"helptext\">Wählen Sie mit Bedacht.</span></p>")
    @test html_eq(as_table(p), "<tr><th>Username:</th><td><input type=\"text\" name=\"username\" maxlength=\"10\" required><br><span class=\"helptext\">e.g., user@example.com</span></td></tr>" *
                               "<tr><th>Password:</th><td><input type=\"password\" name=\"password\" required><br><span class=\"helptext\">Wählen Sie mit Bedacht.</span></td></tr>")
    @test html_eq(as_div(p), "<div>Username: <div class=\"helptext\">e.g., user@example.com</div><input type=\"text\" name=\"username\" maxlength=\"10\" required></div>" *
                             "<div>Password: <div class=\"helptext\">Wählen Sie mit Bedacht.</div><input type=\"password\" name=\"password\" required></div>")
    p = reg(; data = Dict("username" => "foo"), auto_id = false)
    @test html_eq(as_ul(p), "<li>Username: <input type=\"text\" name=\"username\" value=\"foo\" maxlength=\"10\" required><span class=\"helptext\">e.g., user@example.com</span></li>" *
                            "<li><ul class=\"errorlist\"><li>This field is required.</li></ul>Password: <input type=\"password\" name=\"password\" aria-invalid=\"true\" required>" *
                            "<span class=\"helptext\">Wählen Sie mit Bedacht.</span></li>")
    # with ids: the help text's id, and aria-describedby (unless the widget sets its own)
    p = Form([:username => CharField(max_length = 255, help_text = "e.g., user@example.com", widget = Widget(attrs = Dict("aria-describedby" => "custom-description"))),
              :password => CharField(max_length = nothing, widget = :password, help_text = "Wählen Sie mit Bedacht.")])
    @test html_eq(as_div(p), "<div><label for=\"id_username\">Username:</label><div class=\"helptext\" id=\"id_username_helptext\">e.g., user@example.com</div>" *
                             "<input type=\"text\" name=\"username\" maxlength=\"255\" required aria-describedby=\"custom-description\" id=\"id_username\"></div>" *
                             "<div><label for=\"id_password\">Password:</label><div class=\"helptext\" id=\"id_password_helptext\">Wählen Sie mit Bedacht.</div>" *
                             "<input type=\"password\" name=\"password\" required aria-describedby=\"id_password_helptext\" id=\"id_password\"></div>")
    @test html_eq(as_p(p), "<p><label for=\"id_username\">Username:</label><input type=\"text\" name=\"username\" maxlength=\"255\" required aria-describedby=\"custom-description\" id=\"id_username\">" *
                           "<span class=\"helptext\" id=\"id_username_helptext\">e.g., user@example.com</span></p>" *
                           "<p><label for=\"id_password\">Password:</label><input type=\"password\" name=\"password\" required aria-describedby=\"id_password_helptext\" id=\"id_password\">" *
                           "<span class=\"helptext\" id=\"id_password_helptext\">Wählen Sie mit Bedacht.</span></p>")
    # help text and errors together
    p = Form([:color => CharField(max_length = nothing, help_text = "Pick one.")]; data = Dict("color" => ""))
    is_valid(p)
    @test occursin("aria-describedby=\"id_color_helptext id_color_error\"", as_div(p).s)
    # hidden fields: no help text, inside the last row
    p = Form([:username => CharField(max_length = 10, help_text = "e.g., user@example.com"), :password => CharField(max_length = nothing, widget = :password),
              :next => CharField(max_length = nothing, widget = :hidden, default = "/", help_text = "Redirect destination")]; auto_id = false)
    @test html_eq(as_ul(p), "<li>Username: <input type=\"text\" name=\"username\" maxlength=\"10\" required><span class=\"helptext\">e.g., user@example.com</span></li>" *
                            "<li>Password: <input type=\"password\" name=\"password\" required><input type=\"hidden\" name=\"next\" value=\"/\"></li>")
    # a hidden field's errors are the form's, at the top
    p = Form([:first_name => CharField(max_length = nothing), :last_name => CharField(max_length = nothing, widget = :hidden)];
             data = Dict("first_name" => "John"))
    @test !is_valid(p)
    @test html_eq(as_ul(p), "<li><ul class=\"errorlist nonfield\"><li>(Hidden field last_name) This field is required.</li></ul></li>" *
                            "<li><label for=\"id_first_name\">First name:</label><input id=\"id_first_name\" name=\"first_name\" type=\"text\" value=\"John\" required>" *
                            "<input id=\"id_last_name\" name=\"last_name\" type=\"hidden\"></li>")
end

@testset "django forms_tests: test_forms (booleans, widgets, choices, radios, checkboxes, disabled fields)" begin
    signup(data = nothing; kw...) = Form([:email => EmailField(max_length = 320), :get_spam => BooleanField()]; data = data, kw...)
    f = signup(; auto_id = false)
    @test html_eq(w(f[:email]), "<input type=\"email\" name=\"email\" maxlength=\"320\" required>")
    # (a required BooleanField has `required` in Django; Juango's checkbox never does, as it needn't be checked)
    @test html_eq(w(f[:get_spam]), "<input type=\"checkbox\" name=\"get_spam\">")
    f = signup(Dict("email" => "test@example.com", "get_spam" => true); auto_id = false)
    @test html_eq(w(f[:email]), "<input type=\"email\" name=\"email\" maxlength=\"320\" value=\"test@example.com\" required>")
    @test html_eq(w(f[:get_spam]), "<input checked type=\"checkbox\" name=\"get_spam\">")
    for v in ("True", "true")
        @test html_eq(w(signup(Dict("email" => "test@example.com", "get_spam" => v); auto_id = false)[:get_spam]),
                      "<input checked type=\"checkbox\" name=\"get_spam\">")
    end
    for v in ("False", "false")
        @test !occursin("checked", w(signup(Dict("email" => "test@example.com", "get_spam" => v); auto_id = false)[:get_spam]))
    end
    f = signup(Dict("email" => "test@example.com", "get_spam" => "0"))
    @test is_valid(f) && f.cleaned_data[:get_spam] === true          # (a checkbox sent as "0" is checked, #16820)

    # widgets, and as_textarea / as_text / as_hidden
    contact(data = nothing; mw = :textarea, kw...) = Form([:subject => CharField(max_length = nothing), :message => CharField(max_length = nothing, widget = mw)];
                                                          data = data, kw...)
    f = contact(; auto_id = false)
    @test html_eq(w(f[:subject]), "<input type=\"text\" name=\"subject\" required>")
    @test html_eq(w(f[:message]), "<textarea name=\"message\" rows=\"10\" cols=\"40\" required></textarea>")
    @test html_eq(f[:subject].as_textarea, "<textarea name=\"subject\" rows=\"10\" cols=\"40\" required></textarea>")
    @test html_eq(f[:message].as_text, "<input type=\"text\" name=\"message\" required>")
    @test html_eq(f[:message].as_hidden, "<input type=\"hidden\" name=\"message\">")
    f = contact(; mw = Widget(:textarea; attrs = Dict("rows" => 80, "cols" => 20)), auto_id = false)
    @test html_eq(w(f[:message]), "<textarea name=\"message\" rows=\"80\" cols=\"20\" required></textarea>")
    @test html_eq(f[:message].as_text, "<input type=\"text\" name=\"message\" required>")
    f = contact(Dict("subject" => "Hello", "message" => "I love you."); mw = Widget(:textarea; attrs = Dict("rows" => 80, "cols" => 20)), auto_id = false)
    @test html_eq(f[:subject].as_textarea, "<textarea rows=\"10\" cols=\"40\" name=\"subject\" required>Hello</textarea>")
    @test html_eq(f[:message].as_text, "<input type=\"text\" name=\"message\" value=\"I love you.\" required>")
    @test html_eq(f[:message].as_hidden, "<input type=\"hidden\" name=\"message\" value=\"I love you.\">")

    # choices: a select (no `required` without an empty first choice)
    fw(data = nothing; lang = ChoiceField([("P", "Python"), ("J", "Java")]), kw...) =
        Form([:name => CharField(max_length = nothing), :language => lang]; data = data, kw...)
    f = fw(; auto_id = false)
    @test html_eq(w(f[:language]), "<select name=\"language\"><option value=\"P\">Python</option><option value=\"J\">Java</option></select>")
    f = fw(Dict("name" => "Django", "language" => "P"); auto_id = false)
    @test html_eq(w(f[:language]), "<select name=\"language\"><option value=\"P\" selected>Python</option><option value=\"J\">Java</option></select>")
    f = fw(; lang = ChoiceField([("", "------"), ("P", "Python"), ("J", "Java")]), auto_id = false)
    @test html_eq(w(f[:language]), "<select name=\"language\" required><option value=\"\" selected>------</option><option value=\"P\">Python</option><option value=\"J\">Java</option></select>")
    f = fw(; lang = ChoiceField([("P", "Python"), ("J", "Java")]; widget = Widget(attrs = Dict("class" => "foo"))), auto_id = false)
    @test html_eq(w(f[:language]), "<select class=\"foo\" name=\"language\"><option value=\"P\">Python</option><option value=\"J\">Java</option></select>")
    f = fw(; lang = ChoiceField(), auto_id = false)
    @test html_eq(w(f[:language]), "<select name=\"language\"></select>")

    # radios: a div of labelled inputs; the group's label points at none of them, and as_div makes it a fieldset
    radio_lang = ChoiceField([("P", "Python"), ("J", "Java")]; widget = :radio)
    f = fw(; lang = radio_lang, auto_id = false)
    rad(v, l) = "<div><label><input type=\"radio\" name=\"language\" value=\"$v\" required> $l</label></div>"
    @test html_eq(w(f[:language]), "<div>" * rad("P", "Python") * rad("J", "Java") * "</div>")
    @test html_eq(as_table(f), "<tr><th>Name:</th><td><input type=\"text\" name=\"name\" required></td></tr>" *
                               "<tr><th>Language:</th><td><div>" * rad("P", "Python") * rad("J", "Java") * "</div></td></tr>")
    @test html_eq(as_div(f), "<div> Name: <input type=\"text\" name=\"name\" required></div><div><fieldset>Language:<div>" *
                             rad("P", "Python") * rad("J", "Java") * "</div></fieldset></div>")
    f = fw(; lang = radio_lang)
    radi(i, v, l) = "<div><label for=\"id_language_$i\"><input type=\"radio\" id=\"id_language_$i\" value=\"$v\" name=\"language\" required> $l</label></div>"
    radios = "<div id=\"id_language\">" * radi(0, "P", "Python") * radi(1, "J", "Java") * "</div>"
    @test html_eq(w(f[:language]), radios)
    @test html_eq(as_table(f), "<tr><th><label for=\"id_name\">Name:</label></th><td><input type=\"text\" name=\"name\" id=\"id_name\" required></td></tr>" *
                               "<tr><th><label>Language:</label></th><td>" * radios * "</td></tr>")
    @test html_eq(as_p(f), "<p><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" id=\"id_name\" required></p>" *
                           "<p><label>Language:</label>" * radios * "</p>")
    @test html_eq(as_div(f), "<div><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" required id=\"id_name\"></div>" *
                             "<div><fieldset><legend>Language:</legend>" * radios * "</fieldset></div>")
    # the options of a bound field
    beatles = ChoiceField([("john", "John"), ("paul", "Paul"), ("george", "George"), ("ringo", "Ringo")]; widget = :radio)
    opts = collect(Form([:name => beatles])[:name])
    @test length(opts) == 4 && opts[1].id_for_label == "id_name_0" && opts[1].choice_label == "John"
    @test html_eq(opts[1].tag, "<input type=\"radio\" name=\"name\" value=\"john\" id=\"id_name_0\" required>")
    @test html_eq(string(opts[1]), "<label for=\"id_name_0\"><input type=\"radio\" name=\"name\" value=\"john\" id=\"id_name_0\" required> John</label>")
    opts = collect(Form([:name => beatles]; auto_id = false)[:name])
    @test html_eq(join(string.(opts)), join(["<label><input type=\"radio\" name=\"name\" value=\"$(lowercase(n))\" required> $n</label>" for n in ("John", "Paul", "George", "Ringo")]))
    opts = collect(Form([:name => ChoiceField([("john", "John"), ("paul", "Paul")])]; auto_id = false)[:name])
    @test length(opts) == 2 && opts[1].choice_label == "John" && html_eq(opts[1].tag, "<option value=\"john\">John</option>")

    # multiple choices
    song(data = nothing; comp = MultipleChoiceField([("J", "John Lennon"), ("P", "Paul McCartney")]), kw...) =
        Form([:name => CharField(max_length = nothing), :composers => comp]; data = data, kw...)
    @test html_eq(w(song(; comp = MultipleChoiceField([]), auto_id = false)[:composers]), "<select multiple name=\"composers\" required></select>")
    @test html_eq(w(song(; auto_id = false)[:composers]),
                  "<select multiple name=\"composers\" required><option value=\"J\">John Lennon</option><option value=\"P\">Paul McCartney</option></select>")
    f = song(Dict("name" => "Yesterday", "composers" => ["P"]); auto_id = false)
    @test html_eq(w(f[:composers]),
                  "<select multiple name=\"composers\" required><option value=\"J\">John Lennon</option><option value=\"P\" selected>Paul McCartney</option></select>")
    f = song()
    @test html_eq(as_p(f), "<p><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" required id=\"id_name\"></p>" *
                           "<p><label for=\"id_composers\">Composers:</label><select name=\"composers\" required id=\"id_composers\" multiple>" *
                           "<option value=\"J\">John Lennon</option><option value=\"P\">Paul McCartney</option></select></p>")
    # as checkboxes: a group too
    f = song(; comp = MultipleChoiceField([("J", "John Lennon"), ("P", "Paul McCartney")]; widget = :checkboxes))
    boxes = "<div id=\"id_composers\"><div><label for=\"id_composers_0\"><input type=\"checkbox\" name=\"composers\" value=\"J\" id=\"id_composers_0\"> John Lennon</label></div>" *
            "<div><label for=\"id_composers_1\"><input type=\"checkbox\" name=\"composers\" value=\"P\" id=\"id_composers_1\"> Paul McCartney</label></div></div>"
    @test html_eq(as_p(f), "<p><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" required id=\"id_name\"></p><p><label>Composers:</label>" * boxes * "</p>")
    @test html_eq(as_div(f), "<div><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" required id=\"id_name\"></div>" *
                             "<div><fieldset><legend>Composers:</legend>" * boxes * "</fieldset></div>")

    # disabled fields take the initial value, whatever is submitted
    pf(data; field_initial = false, kw...) = Form([:name => CharField(max_length = nothing),
                                                   :birthday => DateField(disabled = true, default = field_initial ? Date(1974, 8, 16) : Juango.NO_DEFAULT)]; data = data, kw...)
    for data in (Dict("name" => "John Doe"), Dict("name" => "John Doe", "birthday" => "1984-11-10"))
        for form in (pf(data; initial = Dict(:birthday => Date(1974, 8, 16))), pf(data; field_initial = true))
            @test is_valid(form) && form.cleaned_data == Dict(:birthday => Date(1974, 8, 16), :name => "John Doe")
        end
    end
    for form in (pf(Dict{String,Any}(); initial = Dict(:birthday => Date(1974, 8, 16))), pf(Dict{String,Any}(); field_initial = true))
        @test !is_valid(form) && form[:birthday].value == Date(1974, 8, 16)
    end

    # a multiple choice as hidden inputs: one per value
    f = song(Dict("name" => "Yesterday", "composers" => ["P"]); auto_id = false)
    @test html_eq(f[:composers].as_hidden, "<input type=\"hidden\" name=\"composers\" value=\"P\">")
    f = song(Dict("name" => "From Me To You", "composers" => ["P", "J"]); auto_id = false)
    @test html_eq(f[:composers].as_hidden, "<input type=\"hidden\" name=\"composers\" value=\"P\"><input type=\"hidden\" name=\"composers\" value=\"J\">")
end

# Django's clean_<field>(): a field's own check, after the field's
@form DftUserRegistration begin
    username = CharField(max_length = 10)
    password1 = CharField(max_length = nothing, widget = :password)
    password2 = CharField(max_length = nothing, widget = :password)
end
function Juango.clean_field(f::Form, ::Val{:DftUserRegistration}, ::Val{:password2}, v)
    cd = f.cleaned_data
    get(cd, :password1, "") != "" && v != "" && cd[:password1] != v && throw(Juango.ValidationError("Please make sure your passwords match."))
    v
end
# the form's clean(): errors for the form, for several fields, and add_error!
@form DftUserRegistration2 begin
    username = CharField(max_length = 10)
    password1 = CharField(max_length = nothing, widget = :password)
    password2 = CharField(max_length = nothing, widget = :password)
end
function Juango.clean_form(f::Form, ::Val{:DftUserRegistration2})
    cd = f.cleaned_data
    p1, p2 = get(cd, :password1, nothing), get(cd, :password2, nothing)
    p1 !== nothing && p2 !== nothing && p1 != p2 && throw(Juango.ValidationError("Please make sure your passwords match."))
    errs = Dict{Symbol,Vector{String}}()
    p1 == "FORBIDDEN_VALUE" && (errs[:password1] = ["Forbidden value."])
    p2 == "FORBIDDEN_VALUE" && (errs[:password2] = ["Forbidden value."])
    isempty(errs) || throw(Juango.ValidationError(errs))
    if p1 == "FORBIDDEN_VALUE2"
        add_error!(f, nothing, "Non-field error 1.")
        add_error!(f, :password1, "Forbidden value 2.")
    end
    if p2 == "FORBIDDEN_VALUE2"
        add_error!(f, :password2, "Forbidden value 2.")
        throw(Juango.ValidationError("Non-field error 2."))
    end
end

@testset "django forms_tests: test_forms (escaping, validating several fields)" begin
    # labels are escaped unless safe; values and errors are escaped
    esc_form(d) = Form([:special_name => CharField(max_length = nothing, label = "<em>Special</em> Field"),
                        :special_safe_name => CharField(max_length = nothing, label = Juango.SafeString("<em>Special</em> Field"))];
                       data = d, auto_id = false, clean = function (f)
                           add_error!(f, :special_name, "Something's wrong with '$(f.cleaned_data[:special_name])'")
                       end)
    f = esc_form(Dict("special_name" => "Should escape < & > and <script>alert('xss')</script>", "special_safe_name" => "<i>Do not escape</i>"))
    t = as_table(f).s
    @test occursin("<th>&lt;em&gt;Special&lt;/em&gt; Field:</th>", t) && occursin("<th><em>Special</em> Field:</th>", t)
    @test occursin("Something&#39;s wrong with &#39;Should escape &lt; &amp; &gt; and &lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;&#39;", t) ||
          occursin("Something&#x27;s wrong with &#x27;Should escape &lt; &amp; &gt; and &lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;&#x27;", t)
    @test occursin("value=\"&lt;i&gt;Do not escape&lt;/i&gt;\"", t)

    # clean_field: the field's error
    @test isempty(DftUserRegistration(; auto_id = false).errors)
    f = DftUserRegistration(Dict{String,Any}(); auto_id = false)
    @test !is_valid(f) && f.errors[:username] == ["This field is required."] && f.errors[:password2] == ["This field is required."]
    f = DftUserRegistration(Dict("username" => "adrian", "password1" => "foo", "password2" => "bar"); auto_id = false)
    @test !is_valid(f) && f.errors[:password2] == ["Please make sure your passwords match."]
    f = DftUserRegistration(Dict("username" => "adrian", "password1" => "foo", "password2" => "foo"); auto_id = false)
    @test is_valid(f) && f.cleaned_data == Dict(:username => "adrian", :password1 => "foo", :password2 => "foo")

    # the form's clean: the form's errors at the top
    f = DftUserRegistration2(Dict{String,Any}(); auto_id = false)
    @test html_eq(as_table(f), "<tr><th>Username:</th><td><ul class=\"errorlist\"><li>This field is required.</li></ul>" *
                               "<input type=\"text\" name=\"username\" maxlength=\"10\" aria-invalid=\"true\" required></td></tr>" *
                               "<tr><th>Password1:</th><td><ul class=\"errorlist\"><li>This field is required.</li></ul><input type=\"password\" name=\"password1\" aria-invalid=\"true\" required></td></tr>" *
                               "<tr><th>Password2:</th><td><ul class=\"errorlist\"><li>This field is required.</li></ul><input type=\"password\" name=\"password2\" aria-invalid=\"true\" required></td></tr>")
    f = DftUserRegistration2(Dict("username" => "adrian", "password1" => "foo", "password2" => "bar"); auto_id = false)
    @test !is_valid(f) && f.errors[:__all__] == ["Please make sure your passwords match."]
    @test html_eq(as_table(f), "<tr><td colspan=\"2\"><ul class=\"errorlist nonfield\"><li>Please make sure your passwords match.</li></ul></td></tr>" *
                               "<tr><th>Username:</th><td><input type=\"text\" name=\"username\" value=\"adrian\" maxlength=\"10\" required></td></tr>" *
                               "<tr><th>Password1:</th><td><input type=\"password\" name=\"password1\" required></td></tr>" *
                               "<tr><th>Password2:</th><td><input type=\"password\" name=\"password2\" required></td></tr>")
    @test html_eq(as_ul(f), "<li><ul class=\"errorlist nonfield\"><li>Please make sure your passwords match.</li></ul></li>" *
                            "<li>Username: <input type=\"text\" name=\"username\" value=\"adrian\" maxlength=\"10\" required></li>" *
                            "<li>Password1: <input type=\"password\" name=\"password1\" required></li><li>Password2: <input type=\"password\" name=\"password2\" required></li>")
    @test html_eq(as_div(f), "<ul class=\"errorlist nonfield\"><li>Please make sure your passwords match.</li></ul>" *
                             "<div>Username: <input type=\"text\" name=\"username\" value=\"adrian\" maxlength=\"10\" required></div>" *
                             "<div>Password1: <input type=\"password\" name=\"password1\" required></div><div>Password2: <input type=\"password\" name=\"password2\" required></div>")
    f = DftUserRegistration2(Dict("username" => "adrian", "password1" => "foo", "password2" => "foo"); auto_id = false)
    @test is_valid(f) && f.cleaned_data[:password2] == "foo"
    f = DftUserRegistration2(Dict("username" => "adrian", "password1" => "FORBIDDEN_VALUE", "password2" => "FORBIDDEN_VALUE"); auto_id = false)
    @test !is_valid(f) && f.errors[:password1] == ["Forbidden value."] && f.errors[:password2] == ["Forbidden value."]
    f = DftUserRegistration2(Dict("username" => "adrian", "password1" => "FORBIDDEN_VALUE2", "password2" => "FORBIDDEN_VALUE2"); auto_id = false)
    @test !is_valid(f) && f.errors[:__all__] == ["Non-field error 1.", "Non-field error 2."]
    @test f.errors[:password1] == ["Forbidden value 2."] && f.errors[:password2] == ["Forbidden value 2."]
    e = try add_error!(f, "missing_field", "Some error.") catch e; e end
    @test e isa ArgumentError && occursin("has no field named", e.msg)
    e = try add_error!(f, :password1, Juango.ValidationError(Dict(:password1 => ["Some error."]))) catch e; e end
    @test e isa ArgumentError && e.msg == "The argument `field` must be `None` when the `error` argument is a dictionary."
    # a ValidationError for fields, given to add_error! with nothing: each field gets its messages
    f = Form([:code => CharField(max_length = 10)]; data = Dict("code" => "x"))
    is_valid(f)
    add_error!(f, nothing, Juango.ValidationError(Dict(:code => ["Code error 1."], :__all__ => ["Non-field error 1."])))
    @test f.errors[:code] == ["Code error 1."] && f.errors[:__all__] == ["Non-field error 1."]
end

@testset "django forms_tests: test_forms (has_error, hidden errors, field order, labels)" begin
    reg(data) = Form([:username => CharField(max_length = 10), :password1 => CharField(max_length = nothing, widget = :password, min_length = 5),
                      :password2 => CharField(max_length = nothing, widget = :password)]; data = data,
                     clean = f -> (p1 = get(f.cleaned_data, :password1, ""); p2 = get(f.cleaned_data, :password2, "");
                                   p1 != "" && p2 != "" && p1 != p2 && throw(Juango.ValidationError("Please make sure your passwords match."; code = "password_mismatch"))))
    f = reg(Dict{String,Any}())
    @test has_error(f, :password1)
    f = reg(Dict("password1" => "Hi", "password2" => "Hi"))
    @test has_error(f, :password1) && !has_error(f, :password2)
    f = reg(Dict("password1" => "Bonjour", "password2" => "Hello"))
    @test !has_error(f, :password1) && has_error(f)
    # (has_error(field, code): Juango's errors don't keep their codes, #234)

    # a hidden field's error, and the form's, with only hidden fields
    f = Form([:hidden_input => CharField(max_length = nothing, widget = :hidden)]; data = Dict{String,Any}(), clean = f -> add_error!(f, nothing, "Form error"))
    @test f[:hidden_input].errors == ["This field is required."]
    @test f.errors == Dict(:hidden_input => ["This field is required."], :__all__ => ["Form error"])
    top = "<ul class=\"errorlist nonfield\"><li>Form error</li><li>(Hidden field hidden_input) This field is required.</li></ul>"
    hid = "<input type=\"hidden\" name=\"hidden_input\" id=\"id_hidden_input\">"
    @test html_eq(as_table(f), "<tr><td colspan=\"2\">" * top * "</td></tr><tr><td colspan=\"2\">" * hid * "</td></tr>") ||
          html_eq(as_table(f), "<tr><td colspan=\"2\">" * top * hid * "</td></tr>")
    @test html_eq(as_p(f), top * "<p>" * hid * "</p>")
    @test html_eq(as_div(f), top * "<div>" * hid * "</div>")

    # fields in the order given, or in field_order (names not there are ignored)
    p = Form([Symbol("field$i") => CharField(max_length = nothing) for i in 1:14]; auto_id = false)
    @test html_eq(as_table(p), join(["<tr><th>Field$i:</th><td><input type=\"text\" name=\"field$i\" required></td></tr>" for i in 1:14]))
    fs6 = [Symbol("field$i") => CharField(max_length = nothing) for i in (1, 2, 4, 5, 6)]
    @test [f.name for f in Form(fs6; field_order = [:field6, :field5, :field4, :field2, :field1]).fields] == [:field6, :field5, :field4, :field2, :field1]
    fs7 = vcat(fs6, [:field3 => CharField(max_length = nothing)])
    @test [f.name for f in Form(fs7; field_order = [:field2, :field4, :field3, :field5, :field6]).fields] == [:field2, :field4, :field3, :field5, :field6, :field1]
    @test [f.name for f in Form(fs7; field_order = [:unknown]).fields] == [:field1, :field2, :field4, :field5, :field6, :field3]

    # max_length makes maxlength (the field's wins over the widget's)
    p = Form([:username => CharField(max_length = 10), :password => CharField(max_length = 10, widget = :password),
              :address => CharField(max_length = nothing)]; auto_id = false)
    @test html_eq(as_ul(p), "<li>Username: <input type=\"text\" name=\"username\" maxlength=\"10\" required></li>" *
                            "<li>Password: <input type=\"password\" name=\"password\" maxlength=\"10\" required></li>" *
                            "<li>Address: <input type=\"text\" name=\"address\" required></li>")
    p = Form([:username => CharField(max_length = 10, widget = Widget(attrs = Dict("maxlength" => 20)))]; auto_id = false)
    @test html_eq(as_ul(p), "<li>Username: <input type=\"text\" name=\"username\" maxlength=\"10\" required></li>")

    # labels: given, made from the name, without a colon after punctuation, or none
    p = Form([:username => CharField(max_length = 10, label = "Your username"), :password1 => CharField(max_length = nothing, widget = :password),
              :password2 => CharField(max_length = nothing, widget = :password, label = "Contraseña (de nuevo)")]; auto_id = false)
    @test html_eq(as_ul(p), "<li>Your username: <input type=\"text\" name=\"username\" maxlength=\"10\" required></li>" *
                            "<li>Password1: <input type=\"password\" name=\"password1\" required></li>" *
                            "<li>Contraseña (de nuevo): <input type=\"password\" name=\"password2\" required></li>")
    qs = [:q1 => "The first question", :q2 => "What is your name?", :q3 => "The answer to life is:", :q4 => "Answer this question!",
          :q5 => "The last question. Period."]
    questions(; kw...) = Form([n => CharField(max_length = nothing, label = l) for (n, l) in qs]; kw...)
    suffixed(l) = last(l) in ":?.!" ? l : l * ":"
    @test html_eq(as_p(questions(; auto_id = false)), join(["<p>$(suffixed(l)) <input type=\"text\" name=\"$n\" required></p>" for (n, l) in qs]))
    @test html_eq(as_p(questions()), join(["<p><label for=\"id_$n\">$(suffixed(l))</label><input type=\"text\" name=\"$n\" id=\"id_$n\" required></p>" for (n, l) in qs]))
    noname(; kw...) = Form([:username => CharField(max_length = 10, label = ""), :password => CharField(max_length = nothing, widget = :password)]; kw...)
    @test html_eq(as_ul(noname(; auto_id = false)), "<li> <input type=\"text\" name=\"username\" maxlength=\"10\" required></li>" *
                                                    "<li>Password: <input type=\"password\" name=\"password\" required></li>")
    @test html_eq(as_ul(noname()), "<li><input id=\"id_username\" type=\"text\" name=\"username\" maxlength=\"10\" required></li>" *
                                   "<li><label for=\"id_password\">Password:</label><input type=\"password\" name=\"password\" id=\"id_password\" required></li>")
end

@testset "django forms_tests: test_forms (label suffix, initial data, changed data, values)" begin
    fav(; kw...) = Form([:color => CharField(max_length = nothing, label = "Favorite color?"), :animal => CharField(max_length = nothing, label = "Favorite animal"),
                         :answer => CharField(max_length = nothing, label = "Secret answer", label_suffix = " =")]; auto_id = false, kw...)
    li(l, n) = "<li>$l <input type=\"text\" name=\"$n\" required></li>"
    @test html_eq(as_ul(fav()), li("Favorite color?", "color") * li("Favorite animal:", "animal") * li("Secret answer =", "answer"))
    @test html_eq(as_ul(fav(; label_suffix = "?")), li("Favorite color?", "color") * li("Favorite animal?", "animal") * li("Secret answer =", "answer"))
    @test html_eq(as_ul(fav(; label_suffix = "")), li("Favorite color?", "color") * li("Favorite animal", "animal") * li("Secret answer =", "answer"))
    @test html_eq(as_ul(fav(; label_suffix = "→")), li("Favorite color?", "color") * li("Favorite animal→", "animal") * li("Secret answer =", "answer"))

    # initial data shows only on an unbound form, and is no fallback for missing data
    reg(data = nothing; uinit = Juango.NO_DEFAULT, kw...) = Form([:username => CharField(max_length = 10, initial = uinit),
                                                                  :password => CharField(max_length = nothing, widget = :password)]; data = data, auto_id = false, kw...)
    pw = "<li>Password: <input type=\"password\" name=\"password\" required></li>"
    req_errs = "<li><ul class=\"errorlist\"><li>This field is required.</li></ul>Username: <input type=\"text\" name=\"username\" maxlength=\"10\" aria-invalid=\"true\" required></li>" *
               "<li><ul class=\"errorlist\"><li>This field is required.</li></ul>Password: <input type=\"password\" name=\"password\" aria-invalid=\"true\" required></li>"
    @test html_eq(as_ul(reg(; uinit = "django")), "<li>Username: <input type=\"text\" name=\"username\" value=\"django\" maxlength=\"10\" required></li>" * pw)
    @test html_eq(as_ul(reg(Dict{String,Any}(); uinit = "django")), req_errs)
    @test html_eq(as_ul(reg(Dict("username" => ""); uinit = "django")), req_errs)
    @test html_eq(as_ul(reg(Dict("username" => "foo"); uinit = "django")),
                  "<li>Username: <input type=\"text\" name=\"username\" value=\"foo\" maxlength=\"10\" required></li>" *
                  "<li><ul class=\"errorlist\"><li>This field is required.</li></ul>Password: <input type=\"password\" name=\"password\" aria-invalid=\"true\" required></li>")
    p = reg(Dict("password" => "secret"); uinit = "django")
    @test !is_valid(p) && p.errors[:username] == ["This field is required."]
    # initial given to the form: the same, and it beats the field's
    @test html_eq(as_ul(reg(; initial = Dict(:username => "stephane"))), "<li>Username: <input type=\"text\" name=\"username\" value=\"stephane\" maxlength=\"10\" required></li>" * pw)
    @test html_eq(as_ul(reg(Dict{String,Any}(); initial = Dict(:username => "django"))), req_errs)
    @test html_eq(as_ul(reg(; uinit = "django", initial = Dict(:username => "babik"))), "<li>Username: <input type=\"text\" name=\"username\" value=\"babik\" maxlength=\"10\" required></li>" * pw)
    # a function as the initial value is called
    opts = MultipleChoiceField([("f", "foo"), ("b", "bar"), ("w", "whiz")])
    p = Form([:username => CharField(max_length = 10), :options => opts]; auto_id = false,
             initial = Dict(:username => () -> "django", :options => () -> ["f", "b"]))
    @test html_eq(as_ul(p), "<li>Username: <input type=\"text\" name=\"username\" value=\"django\" maxlength=\"10\" required></li>" *
                            "<li>Options: <select multiple name=\"options\" required><option value=\"f\" selected>foo</option><option value=\"b\" selected>bar</option>" *
                            "<option value=\"w\">whiz</option></select></li>")

    # changed data: compared with the initial values
    p = Form([:first_name => CharField(max_length = nothing, initial = "Hans"), :last_name => CharField(max_length = nothing, initial = "Greatel"),
              :birthday => DateField(initial = Date(1974, 8, 16))]; data = Dict("first_name" => "Hans", "last_name" => "Scrmbl", "birthday" => "1974-08-16"))
    @test is_valid(p) && changed_fields(p) == [:last_name]

    # a bound field's value: the data, else (unbound) the initial
    reg2(data = nothing) = Form([:username => CharField(max_length = 10, initial = "djangonaut"), :password => CharField(max_length = nothing, widget = :password)]; data = data)
    @test reg2(Dict("password" => "foo"))[:username].value === nothing && reg2()[:username].value == "djangonaut"
    @test reg2(Dict("password" => "foo"))[:password].value == "foo" && reg2()[:password].value === nothing
    # a disabled field's (function) initial value, with or without data
    pf(data = nothing) = Form([:name => CharField(max_length = nothing, initial = () -> "John Doe", disabled = true)]; data = data)
    @test pf()[:name].value == "John Doe" && pf(Dict{String,Any}())[:name].value == "John Doe"
end

@testset "django forms_tests: test_forms (prefixes, NullBooleanField, empty_permitted, hidden and visible fields)" begin
    pdata = Dict("person1-first_name" => "John", "person1-last_name" => "Lennon", "person1-birthday" => "1940-10-9")
    p = DftPerson(pdata; prefix = "person1")
    @test html_eq(as_ul(p), join(["<li><label for=\"id_person1-$n\">$l:</label><input type=\"$t\" name=\"person1-$n\" value=\"$v\" id=\"id_person1-$n\" required></li>"
                                  for (n, l, t, v) in (("first_name", "First name", "text", "John"), ("last_name", "Last name", "text", "Lennon"),
                                                       ("birthday", "Birthday", "date", "1940-10-9"))]))
    @test is_valid(p) && p.cleaned_data == Dict(:first_name => "John", :last_name => "Lennon", :birthday => Date(1940, 10, 9))
    p = DftPerson(Dict("person1-first_name" => "", "person1-last_name" => "", "person1-birthday" => ""); prefix = "person1")
    @test !is_valid(p) && p.errors[:first_name] == ["This field is required."] && p[:first_name].errors == ["This field is required."]
    @test_throws KeyError p[Symbol("person1-first_name")]
    # data without the prefix isn't seen
    p = DftPerson(Dict("first_name" => "John", "last_name" => "Lennon", "birthday" => "1940-10-9"); prefix = "person1")
    @test !is_valid(p) && p.errors[:birthday] == ["This field is required."]
    # one dict for two forms
    both = merge(pdata, Dict("person2-first_name" => "Jim", "person2-last_name" => "Morrison", "person2-birthday" => "1943-12-8"))
    p1, p2 = DftPerson(both; prefix = "person1"), DftPerson(both; prefix = "person2")
    @test is_valid(p1) && p1.cleaned_data[:first_name] == "John" && is_valid(p2) && p2.cleaned_data[:birthday] == Date(1943, 12, 8)

    # NullBooleanField: unknown, yes, no, as Django's NullBooleanSelect reads the data
    nbsel(v) = "<select name=\"is_cool\">" * join(["<option value=\"$k\"$(k == v ? " selected" : "")>$l</option>" for (k, l) in (("unknown", "Unknown"), ("true", "Yes"), ("false", "No"))]) * "</select>"
    cool(d) = Form([:name => CharField(max_length = nothing), :is_cool => NullBooleanField()]; data = merge(Dict{String,Any}("name" => "Joe"), d), auto_id = false)
    for (d, want) in ((Dict{String,Any}(), "unknown"), (Dict{String,Any}("is_cool" => "1"), "unknown"), (Dict{String,Any}("is_cool" => "2"), "true"),
                      (Dict{String,Any}("is_cool" => "3"), "false"), (Dict{String,Any}("is_cool" => true), "true"), (Dict{String,Any}("is_cool" => false), "false"),
                      (Dict{String,Any}("is_cool" => "unknown"), "unknown"), (Dict{String,Any}("is_cool" => "true"), "true"), (Dict{String,Any}("is_cool" => "false"), "false"))
        @test html_eq(w(cool(d)[:is_cool]), nbsel(want))
    end

    # empty_permitted: an untouched form is valid, with nothing cleaned
    song(data; kw...) = Form([:artist => CharField(max_length = nothing), :name => CharField(max_length = nothing)]; data = data, kw...)
    f = song(Dict("artist" => "", "song" => ""))
    @test !is_valid(f) && f.errors == Dict(:name => ["This field is required."], :artist => ["This field is required."]) && isempty(f.cleaned_data)
    f = song(Dict("artist" => "", "song" => ""); empty_permitted = true, use_required_attribute = false)
    @test is_valid(f) && isempty(f.errors) && isempty(f.cleaned_data)
    f = song(Dict("artist" => "The Doors", "song" => ""))
    @test !is_valid(f) && f.errors == Dict(:name => ["This field is required."]) && f.cleaned_data == Dict(:artist => "The Doors")
    f = song(Dict("artist" => nothing, "song" => ""); empty_permitted = true, use_required_attribute = false)
    @test is_valid(f)
    f = Form([:amount => FloatField(), :qty => IntegerField()]; data = Dict("amount" => "0.0", "qty" => ""), initial = Dict(:amount => 0.0),
             empty_permitted = true, use_required_attribute = false)
    @test is_valid(f)
    e = try DftPerson(; empty_permitted = true, use_required_attribute = true) catch e; e end
    @test e isa ArgumentError && e.msg == "The empty_permitted and use_required_attribute arguments may not both be True."

    # hidden and visible fields
    f = Form([:token => CharField(max_length = nothing, widget = :hidden), :artist => CharField(max_length = nothing), :name => CharField(max_length = nothing)])
    @test [bf.name for bf in hidden_fields(f)] == ["token"] && [bf.name for bf in visible_fields(f)] == ["artist", "name"]
end

@testset "django forms_tests: test_forms (file fields)" begin
    ff(; kw...) = Form([:file1 => FileField()]; auto_id = false, kw...)
    row(inner) = "<tr><th>File1:</th><td>$inner</td></tr>"
    @test html_eq(as_table(ff()), row("<input type=\"file\" name=\"file1\" required>"))
    @test html_eq(as_table(ff(; data = Dict{String,Any}(), files = Dict{String,Any}())),
                  row("<ul class=\"errorlist\"><li>This field is required.</li></ul><input type=\"file\" name=\"file1\" aria-invalid=\"true\" required>"))
    @test html_eq(as_table(ff(; data = Dict{String,Any}(), files = Dict{String,Any}("file1" => UploadedFile("name", "")))),
                  row("<ul class=\"errorlist\"><li>The submitted file is empty.</li></ul><input type=\"file\" name=\"file1\" aria-invalid=\"true\" required>"))
    @test html_eq(as_table(ff(; data = Dict{String,Any}(), files = Dict{String,Any}("file1" => "something that is not a file"))),
                  row("<ul class=\"errorlist\"><li>No file was submitted. Check the encoding type on the form.</li></ul>" *
                      "<input type=\"file\" name=\"file1\" aria-invalid=\"true\" required>"))
    f = ff(; data = Dict{String,Any}(), files = Dict{String,Any}("file1" => UploadedFile("name", "some content")))
    @test html_eq(as_table(f), row("<input type=\"file\" name=\"file1\" required>")) && is_valid(f)
    f = ff(; data = Dict{String,Any}(), files = Dict{String,Any}("file1" => UploadedFile("我隻氣墊船裝滿晒鱔.txt", "मेरी मँडराने वाली नाव सर्पमीनों से भरी ह")))
    @test html_eq(as_table(f), row("<input type=\"file\" name=\"file1\" required>"))
    # with a file there already, the input isn't required
    @test html_eq(as_table(ff(; initial = Dict(:file1 => "resume.txt"))), row("<input type=\"file\" name=\"file1\">"))
    # a function as a file field's initial value, kept when no file is sent
    f = Form([:file1 => FileField(initial = () -> "resume.txt")]; data = Dict{String,Any}())
    @test is_valid(f) && isempty(f.errors) && f.cleaned_data[:file1] == "resume.txt"
end

@testset "django forms_tests: test_forms (hidden initial, CSS classes, label_tag)" begin
    # show_hidden_initial: a hidden input with the initial value, with its own id
    @test html_eq(as_table(Form([:field1 => CharField(max_length = 50, show_hidden_initial = true)])),
                  "<tr><th><label for=\"id_field1\">Field1:</label></th><td><input id=\"id_field1\" type=\"text\" name=\"field1\" maxlength=\"50\" required>" *
                  "<input type=\"hidden\" name=\"initial-field1\" id=\"initial-id_field1\"></td></tr>")
    # ...and changed_fields compares the data with it, not with the form's initial
    hf(d) = Form([:f => CharField(max_length = nothing, initial = "a", show_hidden_initial = true)]; data = d)
    @test changed_fields(hf(Dict("f" => "b", "initial-f" => "b"))) == Symbol[]
    @test changed_fields(hf(Dict("f" => "a", "initial-f" => "b"))) == [:f]

    # error_css_class and required_css_class on the rows (sorted, as Django's css_classes) and labels
    person() = (p = Form([:name => CharField(max_length = nothing), :is_cool => NullBooleanField(),
                          :email => EmailField(max_length = 320, blank = true), :age => IntegerField()]; data = Dict{String,Any}());
                p.error_css_class = "error"; p.required_css_class = "required"; p)
    sel = "<select name=\"is_cool\" id=\"id_is_cool\"><option value=\"unknown\" selected>Unknown</option><option value=\"true\">Yes</option><option value=\"false\">No</option></select>"
    nm_err = "<ul class=\"errorlist\" id=\"id_name_error\"><li>This field is required.</li></ul>"
    age_err = "<ul class=\"errorlist\" id=\"id_age_error\"><li>This field is required.</li></ul>"
    nm = "<input type=\"text\" name=\"name\" id=\"id_name\" aria-invalid=\"true\" required aria-describedby=\"id_name_error\">"
    age = "<input type=\"number\" name=\"age\" id=\"id_age\" aria-invalid=\"true\" required aria-describedby=\"id_age_error\">"
    em = "<input type=\"email\" name=\"email\" id=\"id_email\" maxlength=\"320\">"
    lbl(id, t; req = true) = "<label" * (req ? " class=\"required\"" : "") * " for=\"id_$id\">$t:</label>"
    # (Django's NullBooleanField is required, though it accepts no answer; Juango's isn't)
    cool_req = Juango.Form([:x => NullBooleanField()])[:x].field.blank ? "" : " class=\"required\""
    cool_lbl = "<label$cool_req for=\"id_is_cool\">Is cool:</label>"
    @test html_eq(as_ul(person()), "<li class=\"error required\">" * nm_err * lbl("name", "Name") * nm * "</li>" *
                                   "<li$cool_req>" * cool_lbl * sel * "</li><li>" * lbl("email", "Email"; req = false) * em * "</li>" *
                                   "<li class=\"error required\">" * age_err * lbl("age", "Age") * age * "</li>")
    @test html_eq(as_p(person()), nm_err * "<p class=\"error required\">" * lbl("name", "Name") * nm * "</p>" *
                                  "<p$cool_req>" * cool_lbl * sel * "</p><p>" * lbl("email", "Email"; req = false) * em * "</p>" *
                                  age_err * "<p class=\"error required\">" * lbl("age", "Age") * age * "</p>")
    @test html_eq(as_table(person()), "<tr class=\"error required\"><th>" * lbl("name", "Name") * "</th><td>" * nm_err * nm * "</td></tr>" *
                                      "<tr$cool_req><th>" * cool_lbl * "</th><td>" * sel * "</td></tr>" *
                                      "<tr><th>" * lbl("email", "Email"; req = false) * "</th><td>" * em * "</td></tr>" *
                                      "<tr class=\"error required\"><th>" * lbl("age", "Age") * "</th><td>" * age_err * age * "</td></tr>")
    @test html_eq(as_div(person()), "<div class=\"error required\">" * lbl("name", "Name") * nm_err * nm * "</div>" *
                                    "<div$cool_req>" * cool_lbl * sel * "</div><div>" * lbl("email", "Email"; req = false) * em * "</div>" *
                                    "<div class=\"error required\">" * lbl("age", "Age") * age_err * age * "</div>")

    # the required class on label_tag and legend_tag, after any class given
    f = Form([:field => CharField(max_length = 10), :field2 => IntegerField(blank = true)]; data = Dict("field" => "test"), required_css_class = "required")
    @test html_eq(label_tag(f[:field]), "<label for=\"id_field\" class=\"required\">Field:</label>")
    @test html_eq(legend_tag(f[:field]), "<legend class=\"required\">Field:</legend>")
    attrs = Dict("class" => "foo")
    @test html_eq(label_tag(f[:field]; attrs = attrs), "<label for=\"id_field\" class=\"foo required\">Field:</label>")
    @test html_eq(legend_tag(f[:field]; attrs = attrs), "<legend class=\"foo required\">Field:</legend>")
    @test html_eq(legend_tag(f[:field]; attrs = attrs), "<legend class=\"foo required\">Field:</legend>") && attrs == Dict("class" => "foo")
    @test html_eq(label_tag(f[:field2]), "<label for=\"id_field2\">Field2:</label>") && html_eq(legend_tag(f[:field2]), "<legend>Field2:</legend>")

    # hidden split date-times: no label
    @test html_eq(as_ul(Form([:happened_at => SplitDateTimeField(widget = SplitHiddenDateTimeWidget())])),
                  "<input type=\"hidden\" name=\"happened_at_0\" id=\"id_happened_at_0\"><input type=\"hidden\" name=\"happened_at_1\" id=\"id_happened_at_1\">")

    # label_tag's contents (escaped unless safe), attrs and label_suffix
    bf = Form([:field => CharField(max_length = nothing)])[:field]
    for (args, kw, lab, leg) in [((), (;), "<label for=\"id_field\">Field:</label>", "<legend>Field:</legend>"),
                                 (("custom",), (;), "<label for=\"id_field\">custom:</label>", "<legend>custom:</legend>"),
                                 (("custom&",), (;), "<label for=\"id_field\">custom&amp;:</label>", "<legend>custom&amp;:</legend>"),
                                 ((Juango.SafeString("custom&"),), (;), "<label for=\"id_field\">custom&:</label>", "<legend>custom&:</legend>"),
                                 ((), (attrs = Dict("class" => "pretty"),), "<label for=\"id_field\" class=\"pretty\">Field:</label>", "<legend class=\"pretty\">Field:</legend>")]
        @test html_eq(label_tag(bf, args...; kw...), lab) && html_eq(legend_tag(bf, args...; kw...), leg)
    end
    # no id: just the text
    bf = Form([:field => CharField(max_length = nothing)]; auto_id = "")[:field]
    @test label_tag(bf) == "Field:" && legend_tag(bf) == "Field:" && label_tag(bf, "Custom&") == "Custom&amp;:" && legend_tag(bf, "Custom&") == "Custom&amp;:"
    # an empty label
    bf = Form([:field => CharField(max_length = nothing, label = "")])[:field]
    @test html_eq(label_tag(bf), "<label for=\"id_field\"></label>") && html_eq(legend_tag(bf), "<legend></legend>")
    @test Juango.label_id(bf) == "id_field"
    # the widget's own id
    f = Form([:field => CharField(max_length = nothing, widget = Widget(attrs = Dict("id" => "myCustomID")))])
    @test Juango.label_id(f[:field]) == "myCustomID"
    # widget_type
    f = Form([:first_name => CharField(max_length = nothing), :birthday => SplitDateTimeField(widget = SplitHiddenDateTimeWidget())])
    @test Juango.widget_type(f[:first_name].field) == "text" && Juango.widget_type(f[:birthday].field) == "splithiddendatetime"
    # css_classes
    bf = Form([:first_name => CharField(max_length = nothing)])[:first_name]
    @test css_classes(bf) == "" && css_classes(bf; extra_classes = "") == "" && css_classes(bf; extra_classes = "test") == "test" &&
          css_classes(bf; extra_classes = "test test") == "test"
    # the bound field's label_suffix beats the form's
    bf = Form([:field => CharField(max_length = nothing)]; label_suffix = "!")[:field]
    @test html_eq(label_tag(bf; label_suffix = "\$"), "<label for=\"id_field\">Field\$</label>") && html_eq(legend_tag(bf; label_suffix = "\$"), "<legend>Field\$</legend>")
end

@testset "django forms_tests: test_forms (multi-value fields in forms)" begin
    # the field's own validators run on the compressed value; each part's errors are collected
    name_field() = MultiValueField([CharField(label = "First name", max_length = 10), CharField(label = "Last name", max_length = 10)];
                                   compress = vs -> join(vs, " "), decompress = v -> split(v, " "),
                                   validators = [v -> v == "bad value" ? "bad value not allowed" : true])
    nf(a, b) = Form([:name => name_field()]; data = Dict("name_0" => a, "name_1" => b))
    f = nf("bad", "value")
    @test !is_valid(f) && f.errors == Dict(:name => ["bad value not allowed"])
    f = nf("should be overly", "long for the field names")
    @test !is_valid(f) && f.errors == Dict(:name => ["Ensure this value has at most 10 characters (it has 16).",
                                                     "Ensure this value has at most 10 characters (it has 24).",])
    f = nf("fname", "lname")
    @test is_valid(f) && f.cleaned_data == Dict(:name => "fname lname")
    # copying the field copies its parts
    c = name_field(); c2 = deepcopy(c)
    @test c2.related.fields !== c.related.fields && c2.related.fields[1] !== c.related.fields[1]
    # an initial value that isn't valid doesn't break has_changed
    da = MultiValueField([DateField(label = "Date"), IntegerField(label = "Age")]; compress = identity, decompress = identity)
    f = Form([:date_age => da]; data = Dict("date_age_0" => "1998-12-06", "date_age_1" => "16"), initial = Dict(:date_age => ["200-10-10", 14]))
    @test has_changed(f)

    # optional parts: required, not required, and require_all_fields = false
    phone(; kw...) = MultiValueField([CharField(max_length = nothing, label = "Country Code", validators = [RegexValidator(r"^\+[0-9]{1,2}$"; message = "Enter a valid country code.")]),
                                      CharField(max_length = nothing, label = "Phone Number"),
                                      CharField(max_length = nothing, label = "Extension", error_messages = Dict("incomplete" => "Enter an extension.")),
                                      CharField(max_length = nothing, label = "Label", required = false, help_text = "E.g. home, work.")];
                                     compress = vs -> isempty(vs) ? nothing : "$(vs[1]).$(vs[2]) ext. $(vs[3]) (label: $(vs[4]))", decompress = identity, kw...)
    home = ["+61", "287654321", "123", "Home"]
    f = phone()
    @test all(v -> clean_errors(f, v) == ["This field is required."], Any["", nothing, String[], ["+61"], ["+61", "287654321", "123"]])
    @test Juango.clean(f, home) == "+61.287654321 ext. 123 (label: Home)"
    @test clean_errors(f, ["61", "287654321", "123", "Home"]) == ["Enter a valid country code."]
    f = phone(; required = false)
    @test all(v -> Juango.clean(f, v) === nothing, Any["", nothing, String[]])
    @test Juango.clean(f, ["+61"]) == "+61. ext.  (label: )"
    @test Juango.clean(f, ["+61", "287654321", "123"]) == "+61.287654321 ext. 123 (label: )"
    @test Juango.clean(f, home) == "+61.287654321 ext. 123 (label: Home)"
    @test clean_errors(f, ["61", "287654321", "123", "Home"]) == ["Enter a valid country code."]
    f = phone(; require_all_fields = false)
    @test all(v -> clean_errors(f, v) == ["This field is required."], Any["", nothing, String[]])
    @test clean_errors(f, ["+61"]) == ["Enter a complete value.", "Enter an extension."]     # (Django's test checks only the first)
    @test Juango.clean(f, ["+61", "287654321", "123"]) == "+61.287654321 ext. 123 (label: )"
    @test clean_errors(f, ["", "", "", "Home"]) == ["Enter a complete value.", "Enter an extension."]
    @test clean_errors(f, ["61", "287654321", "123", "Home"]) == ["Enter a valid country code."]
    f = phone(; required = false, require_all_fields = false)
    @test all(v -> Juango.clean(f, v) === nothing, Any["", nothing, String[]])
    @test clean_errors(f, ["+61"]) == ["Enter a complete value.", "Enter an extension."]     # (Django's test checks only the first)
    @test Juango.clean(f, ["+61", "287654321", "123"]) == "+61.287654321 ext. 123 (label: )"
    @test clean_errors(f, ["", "", "", "Home"]) == ["Enter a complete value.", "Enter an extension."]
    @test clean_errors(f, ["61", "287654321", "123", "Home"]) == ["Enter a valid country code."]

    # rendering: a part is required only when the field needs it
    ph(; kw...) = MultiValueField([CharField(max_length = nothing), CharField(max_length = nothing, required = false)];
                                  compress = identity, decompress = v -> [nothing, nothing], kw...)
    f = Form([:phone1 => ph(), :phone2 => ph(; required = false), :phone3 => ph(; require_all_fields = false),
              :phone4 => ph(; required = false, require_all_fields = false)]; auto_id = false)
    @test html_eq(as_p(f), "<p>Phone1:<input type=\"text\" name=\"phone1_0\" required><input type=\"text\" name=\"phone1_1\" required></p>" *
                           "<p>Phone2:<input type=\"text\" name=\"phone2_0\"><input type=\"text\" name=\"phone2_1\"></p>" *
                           "<p>Phone3:<input type=\"text\" name=\"phone3_0\" required><input type=\"text\" name=\"phone3_1\"></p>" *
                           "<p>Phone4:<input type=\"text\" name=\"phone4_0\"><input type=\"text\" name=\"phone4_1\"></p>")
end

# clean_<field> raising for a hidden field and a visible one, with characters to escape
@form DftEscaping begin
    hidden = CharField(max_length = nothing, widget = :hidden, required = false)
    visible = CharField(max_length = nothing)
end
Juango.clean_field(::Form, ::Val{:DftEscaping}, ::Val{:hidden}, v) = throw(Juango.ValidationError("Foo & \"bar\"!"))
Juango.clean_field(::Form, ::Val{:DftEscaping}, ::Val{:visible}, v) = throw(Juango.ValidationError("Foo & \"bar\"!"))

@testset "django forms_tests: test_forms (error lists, repr, clean's data, aria_describedby)" begin
    # (ErrorDict/ErrorList as_text, as_ul and error codes: Juango's errors are plain messages, #234)
    # a hidden field's errors: the nonfield class, at the top
    p = Form([:first_name => CharField(max_length = nothing), :last_name => CharField(max_length = nothing, widget = :hidden)]; data = Dict("first_name" => "John"))
    top = "<ul class=\"errorlist nonfield\"><li>(Hidden field last_name) This field is required.</li></ul>"
    fn = "<input id=\"id_first_name\" name=\"first_name\" type=\"text\" value=\"John\" required>"
    ln = "<input id=\"id_last_name\" name=\"last_name\" type=\"hidden\">"
    lab = "<label for=\"id_first_name\">First name:</label>"
    @test html_eq(as_ul(p), "<li>" * top * "</li><li>" * lab * fn * ln * "</li>")
    @test html_eq(as_p(p), top * "<p>" * lab * fn * ln * "</p>")
    @test html_eq(as_table(p), "<tr><td colspan=\"2\">" * top * "</td></tr><tr><th>" * lab * "</th><td>" * fn * ln * "</td></tr>")
    @test html_eq(as_div(p), top * "<div>" * lab * fn * ln * "</div>")
    # the form's own errors: the nonfield class
    p = Form([:first_name => CharField(max_length = nothing), :last_name => CharField(max_length = nothing)];
             data = Dict("first_name" => "John", "last_name" => "Lennon"), clean = f -> throw(Juango.ValidationError("Generic validation error")))
    top = "<ul class=\"errorlist nonfield\"><li>Generic validation error</li></ul>"
    rows(tag) = "<$tag>" * lab * fn * "</$tag><$tag><label for=\"id_last_name\">Last name:</label>" *
                "<input id=\"id_last_name\" name=\"last_name\" type=\"text\" value=\"Lennon\" required></$tag>"
    @test html_eq(as_ul(p), "<li>" * top * "</li>" * rows("li")) && html_eq(as_p(p), top * rows("p")) && html_eq(as_div(p), top * rows("div"))
    @test non_field_errors(p) == ["Generic validation error"]
    # error messages are escaped
    f = DftEscaping(Dict("hidden" => "a", "visible" => "b"))
    is_valid(f)
    @test html_eq(as_ul(f), "<li><ul class=\"errorlist nonfield\"><li>(Hidden field hidden) Foo &amp; &quot;bar&quot;!</li></ul></li>" *
                            "<li><ul class=\"errorlist\" id=\"id_visible_error\"><li>Foo &amp; &quot;bar&quot;!</li></ul>" *
                            "<label for=\"id_visible\">Visible:</label> <input type=\"text\" name=\"visible\" aria-invalid=\"true\" value=\"b\" " *
                            "id=\"id_visible\" required aria-describedby=\"id_visible_error\"><input type=\"hidden\" name=\"hidden\" value=\"a\" id=\"id_hidden\"></li>") ||
          html_eq(replace(as_ul(f).s, "&#34;" => "&quot;"), "<li><ul class=\"errorlist nonfield\"><li>(Hidden field hidden) Foo &amp; &quot;bar&quot;!</li></ul></li>" *
                            "<li><ul class=\"errorlist\" id=\"id_visible_error\"><li>Foo &amp; &quot;bar&quot;!</li></ul>" *
                            "<label for=\"id_visible\">Visible:</label> <input type=\"text\" name=\"visible\" aria-invalid=\"true\" value=\"b\" " *
                            "id=\"id_visible\" required aria-describedby=\"id_visible_error\"><input type=\"hidden\" name=\"hidden\" value=\"a\" id=\"id_hidden\"></li>")

    # repr: whether it's valid is Unknown until validated, and showing it doesn't validate
    @test repr(DftPerson()) == "<DftPerson bound=False, valid=Unknown, fields=(first_name;last_name;birthday)>"
    p = DftPerson(Dict("first_name" => "John", "last_name" => "Lennon", "birthday" => "1940-10-9"))
    @test repr(p) == "<DftPerson bound=True, valid=Unknown, fields=(first_name;last_name;birthday)>"
    is_valid(p)
    @test repr(p) == "<DftPerson bound=True, valid=True, fields=(first_name;last_name;birthday)>"
    p = DftPerson(Dict("first_name" => "John", "last_name" => "Lennon", "birthday" => "fakedate"))
    repr(p)
    @test isempty(p.cleaned_data) && !p.validated
    @test !is_valid(p) && repr(p) == "<DftPerson bound=True, valid=False, fields=(first_name;last_name;birthday)>"
    @test p.cleaned_data == Dict(:first_name => "John", :last_name => "Lennon")

    # clean may change cleaned_data, or return a new dict that replaces it
    uf(clean) = Form([:username => CharField(max_length = 10), :password => CharField(max_length = nothing, widget = :password)];
                     data = Dict("username" => "SirRobin", "password" => "blue"), clean = clean)
    f = uf(function (f)
        d = f.cleaned_data
        isempty(f.errors) && (d[:username] = lowercase(d[:username]))
        d
    end)
    @test is_valid(f) && f.cleaned_data[:username] == "sirrobin"
    f = uf(f -> (f.cleaned_data[:username] = lowercase(f.cleaned_data[:username]); nothing))
    @test is_valid(f) && f.cleaned_data[:username] == "sirrobin"
    f = uf(f -> Dict(:username => lowercase(f.cleaned_data[:username]), :password => "this_is_not_a_secret"))
    @test is_valid(f) && f.cleaned_data[:username] == "sirrobin"

    # multipart: a file or image field
    @test !is_multipart(Form([:username => CharField(max_length = nothing)]))
    @test is_multipart(Form([:username => CharField(max_length = nothing), :file => FileField()]))
    @test is_multipart(Form([:image => ImageField()]))
    # only hidden fields, with errors
    f = Form([:data => IntegerField(widget = :hidden)]; data = Dict{String,Any}())
    top = "<ul class=\"errorlist nonfield\"><li>(Hidden field data) This field is required.</li></ul>"
    @test html_eq(as_p(f), top * "<p> <input type=\"hidden\" name=\"data\" id=\"id_data\"></p>")
    @test html_eq(as_table(f), "<tr><td colspan=\"2\">" * top * "</td></tr><tr><td colspan=\"2\"><input type=\"hidden\" name=\"data\" id=\"id_data\"></td></tr>") ||
          html_eq(as_table(f), "<tr><td colspan=\"2\">" * top * "<input type=\"hidden\" name=\"data\" id=\"id_data\"></td></tr>")
    # a field named data
    f = Form([:data => CharField(max_length = 10)]; data = Dict("data" => "xyzzy"))
    @test is_valid(f) && f.cleaned_data == Dict(:data => "xyzzy")
    # copying a field copies its error messages
    c = CharField(max_length = nothing, error_messages = Dict("invalid" => "Form custom error message."))
    @test deepcopy(c).error_messages !== c.error_messages
    # labels: no new line; attributes not localized
    bf = DftPerson()[:first_name]
    @test label_tag(bf) == "<label for=\"id_first_name\">First name:</label>" && legend_tag(bf) == "<legend>First name:</legend>"
    @test html_eq(label_tag(bf; attrs = Dict("number" => 9999)), "<label number=\"9999\" for=\"id_first_name\">First name:</label>")
    @test html_eq(legend_tag(bf; attrs = Dict("number" => 9999)), "<legend number=\"9999\">First name:</legend>")
    # a removed field is gone
    f = Form([:name => CharField(max_length = 10)]; data = Dict("name" => "abcde"))
    collect(f)
    delete_field!(f, :name)
    @test_throws KeyError f[:name]

    # aria_describedby: the help text's id; "" without one (or with no id, or hidden); nothing when the widget sets its own
    @test aria_describedby(Form([:name => CharField(max_length = nothing, help_text = "Some help text")]; data = Dict("name" => "MyName"))[:name]) == "id_name_helptext"
    @test aria_describedby(Form([:name => CharField(max_length = nothing, help_text = "Some help text")]; auto_id = nothing)[:name]) == ""
    @test aria_describedby(Form([:name => CharField(max_length = nothing, help_text = "Some help text", widget = :hidden)])[:name]) == ""
    @test aria_describedby(Form([:name => CharField(max_length = nothing, widget = Widget(attrs = Dict("aria-describedby" => "my-id")))]; data = Dict("name" => "MyName"))[:name]) === nothing
    @test aria_describedby(Form([:name => CharField(max_length = nothing)])[:name]) == ""
end

@testset "django forms_tests: test_forms (use_required_attribute)" begin
    mf(req) = Form([:f1 => CharField(max_length = 30), :f2 => CharField(max_length = 30, required = false),
                    :f3 => CharField(max_length = nothing, widget = :textarea), :f4 => ChoiceField([("P", "Python"), ("J", "Java")])];
                   use_required_attribute = req)
    for req in (true, false)
        r = req ? " required" : ""
        f1 = "<label for=\"id_f1\">F1:</label><input id=\"id_f1\" maxlength=\"30\" name=\"f1\" type=\"text\"$r>"
        f2 = "<label for=\"id_f2\">F2:</label><input id=\"id_f2\" maxlength=\"30\" name=\"f2\" type=\"text\">"
        f3 = "<label for=\"id_f3\">F3:</label><textarea cols=\"40\" id=\"id_f3\" name=\"f3\" rows=\"10\"$r></textarea>"
        f4 = "<label for=\"id_f4\">F4:</label><select id=\"id_f4\" name=\"f4\"><option value=\"P\">Python</option><option value=\"J\">Java</option></select>"
        rows(tag) = join("<$tag>" * x * "</$tag>" for x in (f1, f2, f3, f4))
        @test html_eq(as_p(mf(req)), rows("p")) && html_eq(as_ul(mf(req)), rows("li")) && html_eq(as_div(mf(req)), rows("div"))
        @test html_eq(as_table(mf(req)), join("<tr><th>" * replace(x, r"(</label>)" => s"\1</th><td>") * "</td></tr>" for x in (f1, f2, f3, f4)))
    end
end

@testset "django forms_tests: test_forms (templates)" begin
    t(src, f) = render(Template(src), Dict{String,Any}("form" => f))
    # iterating a radio group and a checkbox group
    fw = Form([:name => CharField(max_length = nothing), :language => ChoiceField([("P", "Python"), ("J", "Java")]; widget = :radio)])
    @test html_eq(t("{% for radio in form.language %}<div class=\"myradio\">{{ radio }}</div>{% endfor %}", fw),
                  "<div class=\"myradio\"><label for=\"id_language_0\"><input id=\"id_language_0\" name=\"language\" type=\"radio\" value=\"P\" required> Python</label></div>" *
                  "<div class=\"myradio\"><label for=\"id_language_1\"><input id=\"id_language_1\" name=\"language\" type=\"radio\" value=\"J\" required> Java</label></div>")
    song = Form([:name => CharField(max_length = nothing), :composers => MultipleChoiceField([("J", "John Lennon"), ("P", "Paul McCartney")]; widget = :checkboxes)];
                data = Dict("composers" => ["J", "P"]), auto_id = false)
    @test html_eq(t("{% for checkbox in form.composers %}<div class=\"mycheckbox\">{{ checkbox }}</div>{% endfor %}", song),
                  "<div class=\"mycheckbox\"><label><input checked name=\"composers\" type=\"checkbox\" value=\"J\"> John Lennon</label></div>" *
                  "<div class=\"mycheckbox\"><label><input checked name=\"composers\" type=\"checkbox\" value=\"P\"> Paul McCartney</label></div>")

    # fields one by one in a template, with their errors (ErrorList.as_ul) and the form's (non_field_errors)
    reg(data = nothing; auto_id = false) =
        Form([:username => CharField(max_length = 10, help_text = "Good luck picking a username that doesn't already exist."),
              :password1 => CharField(max_length = nothing, widget = :password), :password2 => CharField(max_length = nothing, widget = :password)];
             data = data, auto_id = auto_id,
             clean = f -> (p1 = get(f.cleaned_data, :password1, ""); p2 = get(f.cleaned_data, :password2, "");
                           p1 != "" && p2 != "" && p1 != p2 && throw(Juango.ValidationError("Please make sure your passwords match."))))
    src = "<form>{{ form.username.errors.as_ul }}<p><label>Your username: {{ form.username }}</label></p>" *
          "{{ form.password1.errors.as_ul }}<p><label>Password: {{ form.password1 }}</label></p>" *
          "{{ form.password2.errors.as_ul }}<p><label>Password (again): {{ form.password2 }}</label></p><input type=\"submit\" required></form>"
    un(v = "") = "<input type=\"text\" name=\"username\"" * (isempty(v) ? "" : " value=\"$v\"") * " maxlength=\"10\" required>"
    pw(n; inv = false) = "<input type=\"password\" name=\"$n\"" * (inv ? " aria-invalid=\"true\"" : "") * " required>"
    @test html_eq(t(src, reg()), "<form><p><label>Your username: " * un() * "</label></p><p><label>Password: " * pw("password1") *
                                 "</label></p><p><label>Password (again): " * pw("password2") * "</label></p><input type=\"submit\" required></form>")
    req_err = "<ul class=\"errorlist\"><li>This field is required.</li></ul>"
    @test html_eq(t(src, reg(Dict("username" => "django"))),
                  "<form><p><label>Your username: " * un("django") * "</label></p>" * req_err * "<p><label>Password: " * pw("password1"; inv = true) *
                  "</label></p>" * req_err * "<p><label>Password (again): " * pw("password2"; inv = true) * "</label></p><input type=\"submit\" required></form>")
    # the label
    @test html_eq(t("<form><p><label>{{ form.username.label }}: {{ form.username }}</label></p><p><label>{{ form.password1.label }}: {{ form.password1 }}</label></p></form>", reg()),
                  "<form><p><label>Username: " * un() * "</label></p><p><label>Password1: " * pw("password1") * "</label></p></form>")
    # label_tag: just the text without ids
    lt = "<form><p>{{ form.username.label_tag }} {{ form.username }}<span {% if form.username.id_for_label %}id=\"{{ form.username.id_for_label }}_helptext\"{% endif %}>" *
         "{{ form.username.help_text }}</span></p><p>{{ form.password1.label_tag }} {{ form.password1 }}</p></form>"
    @test html_eq(replace(t(lt, reg()), "&#39;" => "'", "&#x27;" => "'"),
                  "<form><p>Username: " * un() * "<span>Good luck picking a username that doesn't already exist.</span></p><p>Password1: " * pw("password1") * "</p></form>")
    @test html_eq(replace(t(lt, reg(; auto_id = "id_%s")), "&#39;" => "'", "&#x27;" => "'"),
                  "<form><p><label for=\"id_username\">Username:</label><input id=\"id_username\" type=\"text\" name=\"username\" maxlength=\"10\" " *
                  "aria-describedby=\"id_username_helptext\" required><span id=\"id_username_helptext\">Good luck picking a username that doesn't already exist.</span></p>" *
                  "<p><label for=\"id_password1\">Password1:</label><input type=\"password\" name=\"password1\" id=\"id_password1\" required></p></form>")
    # legend_tag
    lg = "<form><p>{{ form.username.legend_tag }} {{ form.username }}</p><p>{{ form.password1.legend_tag }} {{ form.password1 }}</p></form>"
    @test html_eq(t(lg, reg()), "<form><p>Username: " * un() * "</p><p>Password1: " * pw("password1") * "</p></form>")
    @test html_eq(t(lg, reg(; auto_id = "id_%s")),
                  "<form><p><legend>Username:</legend><input id=\"id_username\" type=\"text\" name=\"username\" maxlength=\"10\" aria-describedby=\"id_username_helptext\" required></p>" *
                  "<p><legend>Password1:</legend><input type=\"password\" name=\"password1\" id=\"id_password1\" required></p></form>")
    # help text, escaped; none for a field without
    @test occursin("Good luck picking a username that doesn&#", t("{{ form.username.help_text }}", reg()))
    @test t("{{ form.password1.help_text }}", reg()) == ""
    # the form's own errors show only where the template puts non_field_errors
    bad = reg(Dict("username" => "django", "password1" => "foo", "password2" => "bar"))
    ok = "<p><label>Your username: " * un("django") * "</label></p><p><label>Password: " * pw("password1") *
         "</label></p><p><label>Password (again): " * pw("password2") * "</label></p><input type=\"submit\" required></form>"
    @test html_eq(t(src, bad), "<form>" * ok)
    @test html_eq(t("<form>{{ form.non_field_errors }}" * src[7:end], bad),
                  "<form><ul class=\"errorlist nonfield\"><li>Please make sure your passwords match.</li></ul>" * ok)
    # ErrorList: a vector of messages, as_ul and as_text
    e = ErrorList(["Foo", "Foobar"])
    @test e == ["Foo", "Foobar"] && "Foo" in e
    @test Juango.errors_text(e) == "* Foo\n* Foobar" && as_ul(e).s == "<ul class=\"errorlist\"><li>Foo</li><li>Foobar</li></ul>"
    @test as_ul(ErrorList(["Foo"]; error_class = "foobar-error-class")).s == "<ul class=\"errorlist foobar-error-class\"><li>Foo</li></ul>"
end
