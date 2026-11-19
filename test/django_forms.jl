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
    # a required BooleanField must be checked (#247)
    @test raises(BooleanField(), false, "This field is required.") && raises(BooleanField(), "", "This field is required.") &&
          Juango.clean(BooleanField(), true) === true
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
    @test html_eq(w(f[:get_spam]), "<input type=\"checkbox\" name=\"get_spam\" required>")
    f = signup(Dict("email" => "test@example.com", "get_spam" => true); auto_id = false)
    @test html_eq(w(f[:email]), "<input type=\"email\" name=\"email\" maxlength=\"320\" value=\"test@example.com\" required>")
    @test html_eq(w(f[:get_spam]), "<input checked type=\"checkbox\" name=\"get_spam\" required>")
    for v in ("True", "true")
        @test html_eq(w(signup(Dict("email" => "test@example.com", "get_spam" => v); auto_id = false)[:get_spam]),
                      "<input checked type=\"checkbox\" name=\"get_spam\" required>")
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

# ---- Django's forms_tests/tests/test_formsets.py. Juango differences: cleaned_data(fs) is the counted forms' data
# (Django's formset.cleaned_data is every form's: [f.cleaned_data for f in fs.forms]).

@form DfsChoice begin
    choice = CharField(max_length = nothing)
    votes = IntegerField()
end
@form DfsDrink begin
    name = CharField(max_length = nothing)
end
@form DfsArticle begin
    title = CharField(max_length = nothing)
    pub_date = DateField()
end
const DfsChoiceFormSet = formset_factory(DfsChoice)
# a form constructor for a list of fields (Django: a Form class declared in the test)
dfs_form(fields) = (d = nothing; kw...) -> Form(deepcopy(fields); data = d, kw...)
function dfs_drinks_clean(fs)
    seen = String[]
    for f in fs.forms
        n = get(f.cleaned_data, :name, nothing)
        n === nothing && continue
        n in seen && throw(Juango.ValidationError("You may only specify a drink once."))
        push!(seen, n)
    end
end
const DfsDrinksFormSet = formset_factory(DfsDrink; extra = 3, clean = dfs_drinks_clean)

# Django's make_choiceformset: (choice, votes) pairs as a bound formset, prefix "choices", no ids
function dfs_choices(data = nothing; fs = DfsChoiceFormSet, total = nothing, initial_forms = 0, max_num_forms = 0, min_num_forms = 0,
                     prefix = "choices", auto_id = false, kw...)
    data === nothing && return fs(; prefix = prefix, auto_id = auto_id, kw...)
    d = Dict{String,Any}("$prefix-TOTAL_FORMS" => string(something(total, length(data))), "$prefix-INITIAL_FORMS" => string(initial_forms),
                         "$prefix-MAX_NUM_FORMS" => string(max_num_forms), "$prefix-MIN_NUM_FORMS" => string(min_num_forms))
    for (i, (c, v)) in enumerate(data)
        d["$prefix-$(i-1)-choice"] = c
        d["$prefix-$(i-1)-votes"] = v
    end
    fs(d; prefix = prefix, auto_id = auto_id, kw...)
end
dfs_ul(fs) = join([as_ul(f).s for f in fs.forms], "\n")
mgmt(p, t, i, mn, mx) = "<input type=\"hidden\" name=\"$p-TOTAL_FORMS\" value=\"$t\"><input type=\"hidden\" name=\"$p-INITIAL_FORMS\" value=\"$i\">" *
                        "<input type=\"hidden\" name=\"$p-MIN_NUM_FORMS\" value=\"$mn\"><input type=\"hidden\" name=\"$p-MAX_NUM_FORMS\" value=\"$mx\">"
li_choice(i; c = "", v = "") = "<li>Choice: <input type=\"text\" name=\"choices-$i-choice\"" * (isempty(c) ? "" : " value=\"$c\"") * "></li>" *
                               "<li>Votes: <input type=\"number\" name=\"choices-$i-votes\"" * (isempty(v) ? "" : " value=\"$v\"") * "></li>"

@testset "django forms_tests: test_formsets (basics, validation, initial data)" begin
    fs = dfs_choices()
    @test html_eq(as_div(fs), mgmt("choices", 1, 0, 0, 1000) * "<div>Choice:<input type=\"text\" name=\"choices-0-choice\"></div>" *
                              "<div>Votes:<input type=\"number\" name=\"choices-0-votes\"></div>")
    fs = dfs_choices([("Calexico", "100")])
    @test is_valid(fs) && [f.cleaned_data for f in fs.forms] == [Dict(:votes => 100, :choice => "Calexico")]
    fs = dfs_choices()
    @test !is_valid(fs) && !has_changed(fs)
    @test repr(DfsChoiceFormSet()) == "<DfsChoiceFormSet: bound=False valid=Unknown total_forms=1>"

    # form_kwargs: given to every form; the empty form is always empty_permitted
    @test all(f -> f.label_suffix == "!", formset_factory(DfsChoice; extra = 2)(; form_kwargs = Dict(:label_suffix => "!")))
    @test Juango.empty_form(formset_factory(DfsChoice)(; form_kwargs = Dict(:label_suffix => "!"))).label_suffix == "!"
    @test Juango.empty_form(formset_factory(DfsArticle)(; form_kwargs = Dict(:empty_permitted => false, :use_required_attribute => false))).empty_permitted

    fs = dfs_choices([("Calexico", "")])
    @test !is_valid(fs) && Juango.errors(fs) == [Dict(:votes => ["This field is required."])]
    # has_changed: any form's data, valid or not
    @test !has_changed(dfs_choices([("", "")]))
    fs = dfs_choices([("Calexico", "")]); @test !is_valid(fs) && has_changed(fs)
    fs = dfs_choices([("Calexico", "100")]); @test is_valid(fs) && has_changed(fs)
    # initial data, and an extra blank form
    @test html_eq(dfs_ul(dfs_choices(; initial = [Dict(:choice => "Calexico", :votes => 100)])), li_choice(0; c = "Calexico", v = "100") * li_choice(1))
    # a form displayed blank may be submitted blank
    fs = dfs_choices([("Calexico", "100"), ("", "")]; initial_forms = 1)
    @test is_valid(fs) && [f.cleaned_data for f in fs.forms] == [Dict(:votes => 100, :choice => "Calexico"), Dict()]
    # ...but one partly filled is validated
    fs = dfs_choices([("Calexico", "100"), ("The Decemberists", "")]; initial_forms = 1)
    @test !is_valid(fs) && Juango.errors(fs) == [Dict(), Dict(:votes => ["This field is required."])]
    # emptying an initial form is an error, not a deletion
    fs = dfs_choices([("", ""), ("", "")]; initial_forms = 1)
    @test !is_valid(fs) && Juango.errors(fs) == [Dict(:votes => ["This field is required."], :choice => ["This field is required."]), Dict()]

    # extra forms, and min_num (which forms are required)
    F3 = formset_factory(DfsChoice; extra = 3)
    @test html_eq(dfs_ul(F3(; auto_id = false, prefix = "choices")), li_choice(0) * li_choice(1) * li_choice(2))
    blank3 = Dict("choices-TOTAL_FORMS" => "3", "choices-INITIAL_FORMS" => "0", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "0",
                  ("choices-$i-$n" => "" for i in 0:2, n in ("choice", "votes"))...)
    fs = F3(blank3; auto_id = false, prefix = "choices")
    @test is_valid(fs) && [f.cleaned_data for f in fs.forms] == [Dict(), Dict(), Dict()]
    fs = formset_factory(DfsChoice; extra = 1, min_num = 1)(; auto_id = false, prefix = "choices")
    @test !fs.forms[1].empty_permitted && fs.forms[2].empty_permitted
    @test html_eq(dfs_ul(fs), li_choice(0) * li_choice(1))
    @test html_eq(dfs_ul(formset_factory(DfsChoice; extra = 0, min_num = 3)(; auto_id = false, prefix = "choices")), li_choice(0) * li_choice(1) * li_choice(2))
    # just one form completed
    fs = F3(merge(blank3, Dict("choices-0-choice" => "Calexico", "choices-0-votes" => "100")); auto_id = false, prefix = "choices")
    @test is_valid(fs) && [f.cleaned_data for f in fs.forms] == [Dict(:votes => 100, :choice => "Calexico"), Dict(), Dict()]

    # validate_max and validate_min, with their messages (and custom ones)
    two = Dict("choices-TOTAL_FORMS" => "2", "choices-INITIAL_FORMS" => "0", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "2",
               "choices-0-choice" => "Zero", "choices-0-votes" => "0", "choices-1-choice" => "One", "choices-1-votes" => "1")
    FMax = formset_factory(DfsChoice; extra = 1, max_num = 1, validate_max = true)
    fs = FMax(two; auto_id = false, prefix = "choices")
    @test !is_valid(fs) && non_form_errors(fs) == ["Please submit at most 1 form."]
    @test as_ul(non_form_errors(fs)).s == "<ul class=\"errorlist nonform\"><li>Please submit at most 1 form.</li></ul>"
    fs = FMax(two; auto_id = false, prefix = "choices", error_messages = Dict("too_many_forms" => "Number of submitted forms should be at most %(num)d."))
    @test !is_valid(fs) && non_form_errors(fs) == ["Number of submitted forms should be at most 1."]
    FMin = formset_factory(DfsChoice; extra = 1, min_num = 3, validate_min = true)
    fs = FMin(two; auto_id = false, prefix = "choices")
    @test !is_valid(fs) && non_form_errors(fs) == ["Please submit at least 3 forms."]
    fs = FMin(two; auto_id = false, prefix = "choices", error_messages = Dict("too_few_forms" => "Number of submitted forms should be at least %(num)d."))
    @test !is_valid(fs) && non_form_errors(fs) == ["Number of submitted forms should be at least 3."]
    # unchanged initial forms count for min_num; empty extra forms don't
    fs = formset_factory(DfsChoice; min_num = 2, validate_min = true)(merge(two, Dict("choices-INITIAL_FORMS" => "2"));
             auto_id = false, prefix = "choices", initial = [Dict(:choice => "Zero", :votes => 0), Dict(:choice => "One", :votes => 0)])
    @test !has_changed(fs.forms[1]) && has_changed(fs.forms[2]) && is_valid(fs)
    fs = formset_factory(DfsChoice; extra = 2, min_num = 1, validate_min = true, can_delete = true)(Dict("choices-TOTAL_FORMS" => "2", "choices-INITIAL_FORMS" => "0"); prefix = "choices")
    @test !has_changed(fs) && !is_valid(fs) && non_form_errors(fs) == ["Please submit at least 1 form."]
    # a partly completed form among blank ones
    fs = F3(merge(blank3, Dict("choices-0-choice" => "Calexico", "choices-0-votes" => "100", "choices-1-choice" => "The Decemberists")); auto_id = false, prefix = "choices")
    @test !is_valid(fs) && Juango.errors(fs) == [Dict(), Dict(:votes => ["This field is required."]), Dict()]
    # more initial data, and the empty form
    fs = F3(; initial = [Dict(:choice => "Calexico", :votes => 100)], auto_id = false, prefix = "choices")
    @test html_eq(dfs_ul(fs), li_choice(0; c = "Calexico", v = "100") * li_choice(1) * li_choice(2) * li_choice(3))
    @test Juango.empty_form(fs).empty_permitted && html_eq(as_ul(Juango.empty_form(fs)), li_choice("__prefix__"))
end

@testset "django forms_tests: test_formsets (deletion, ordering, clean)" begin
    # (Juango puts a checkbox before its label)
    li_del(i) = "<li><input type=\"checkbox\" name=\"choices-$i-DELETE\"> Delete:</li>"
    li_ord(i, v = "") = "<li>Order: <input type=\"number\" name=\"choices-$i-ORDER\"" * (isempty(v) ? "" : " value=\"$v\"") * "></li>"
    init2 = [Dict(:choice => "Calexico", :votes => 100), Dict(:choice => "Fergie", :votes => 900)]
    FDel = formset_factory(DfsChoice; can_delete = true)
    @test html_eq(dfs_ul(FDel(; initial = init2, auto_id = false, prefix = "choices")),
                  li_choice(0; c = "Calexico", v = "100") * li_del(0) * li_choice(1; c = "Fergie", v = "900") * li_del(1) * li_choice(2) * li_del(2))
    d = Dict("choices-TOTAL_FORMS" => "3", "choices-INITIAL_FORMS" => "2", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "0",
             "choices-0-choice" => "Calexico", "choices-0-votes" => "100", "choices-0-DELETE" => "",
             "choices-1-choice" => "Fergie", "choices-1-votes" => "900", "choices-1-DELETE" => "on",
             "choices-2-choice" => "", "choices-2-votes" => "", "choices-2-DELETE" => "")
    fs = FDel(d; auto_id = false, prefix = "choices")
    @test is_valid(fs)
    @test [f.cleaned_data for f in fs.forms] == [Dict(:votes => 100, :DELETE => false, :choice => "Calexico"), Dict(:votes => 900, :DELETE => true, :choice => "Fergie"), Dict()]
    @test [f.cleaned_data for f in Juango.deleted_forms(fs)] == [Dict(:votes => 900, :DELETE => true, :choice => "Fergie")]
    # a form ticked for deletion: its errors don't count
    CheckFS = formset_factory(dfs_form([:field => IntegerField(min_value = 100)]); can_delete = true)
    cd_ = Dict("check-TOTAL_FORMS" => "3", "check-INITIAL_FORMS" => "2", "check-MAX_NUM_FORMS" => "0",
               "check-0-field" => "200", "check-0-DELETE" => "", "check-1-field" => "50", "check-1-DELETE" => "on", "check-2-field" => "", "check-2-DELETE" => "")
    @test is_valid(CheckFS(cd_; prefix = "check"))
    @test !is_valid(CheckFS(merge(cd_, Dict("check-1-DELETE" => "")); prefix = "check"))
    fs = formset_factory(DfsDrink; can_delete = true)(Dict("form-0-name" => "", "form-0-DELETE" => "on", "form-TOTAL_FORMS" => 1,
                                                           "form-INITIAL_FORMS" => 1, "form-MIN_NUM_FORMS" => 0, "form-MAX_NUM_FORMS" => 1))
    @test is_valid(fs) && Juango.errors(fs) == [] && length(Juango.deleted_forms(fs)) == 1

    # ordering: ORDER fields, blank last, then by position
    FOrd = formset_factory(DfsChoice; can_order = true)
    @test html_eq(dfs_ul(FOrd(; initial = init2, auto_id = false, prefix = "choices")),
                  li_choice(0; c = "Calexico", v = "100") * li_ord(0, "1") * li_choice(1; c = "Fergie", v = "900") * li_ord(1, "2") * li_choice(2) * li_ord(2))
    od = Dict("choices-TOTAL_FORMS" => "3", "choices-INITIAL_FORMS" => "2", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "0",
              "choices-0-choice" => "Calexico", "choices-0-votes" => "100", "choices-0-ORDER" => "1",
              "choices-1-choice" => "Fergie", "choices-1-votes" => "900", "choices-1-ORDER" => "2",
              "choices-2-choice" => "The Decemberists", "choices-2-votes" => "500", "choices-2-ORDER" => "0")
    fs = FOrd(od; auto_id = false, prefix = "choices")
    @test is_valid(fs) && [f.cleaned_data for f in Juango.ordered_forms(fs)] ==
          [Dict(:votes => 500, :ORDER => 0, :choice => "The Decemberists"), Dict(:votes => 100, :ORDER => 1, :choice => "Calexico"), Dict(:votes => 900, :ORDER => 2, :choice => "Fergie")]
    od4 = merge(od, Dict("choices-TOTAL_FORMS" => "4", "choices-INITIAL_FORMS" => "3", "choices-2-ORDER" => "",
                         "choices-3-choice" => "Basia Bulat", "choices-3-votes" => "50", "choices-3-ORDER" => ""))
    fs = FOrd(od4; auto_id = false, prefix = "choices")
    @test is_valid(fs) && [f.cleaned_data[:choice] for f in Juango.ordered_forms(fs)] == ["Calexico", "Fergie", "The Decemberists", "Basia Bulat"] &&
          Juango.ordered_forms(fs)[3].cleaned_data[:ORDER] === nothing
    fs = FOrd(Dict("choices-TOTAL_FORMS" => "3", "choices-INITIAL_FORMS" => "0", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "0"); auto_id = false, prefix = "choices")
    @test is_valid(fs) && Juango.ordered_forms(fs) == []
    # ordering and deletion together
    FOD = formset_factory(DfsChoice; can_order = true, can_delete = true)
    init3 = vcat(init2, [Dict(:choice => "The Decemberists", :votes => 500)])
    @test html_eq(dfs_ul(FOD(; initial = init3, auto_id = false, prefix = "choices")),
                  li_choice(0; c = "Calexico", v = "100") * li_ord(0, "1") * li_del(0) * li_choice(1; c = "Fergie", v = "900") * li_ord(1, "2") * li_del(1) *
                  li_choice(2; c = "The Decemberists", v = "500") * li_ord(2, "3") * li_del(2) * li_choice(3) * li_ord(3) * li_del(3))
    odd = Dict("choices-TOTAL_FORMS" => "4", "choices-INITIAL_FORMS" => "3", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "0",
               "choices-0-choice" => "Calexico", "choices-0-votes" => "100", "choices-0-ORDER" => "1", "choices-0-DELETE" => "",
               "choices-1-choice" => "Fergie", "choices-1-votes" => "900", "choices-1-ORDER" => "2", "choices-1-DELETE" => "on",
               "choices-2-choice" => "The Decemberists", "choices-2-votes" => "500", "choices-2-ORDER" => "0", "choices-2-DELETE" => "",
               "choices-3-choice" => "", "choices-3-votes" => "", "choices-3-ORDER" => "", "choices-3-DELETE" => "")
    fs = FOD(odd; auto_id = false, prefix = "choices")
    @test is_valid(fs)
    @test [f.cleaned_data for f in Juango.ordered_forms(fs)] == [Dict(:votes => 500, :DELETE => false, :ORDER => 0, :choice => "The Decemberists"),
                                                          Dict(:votes => 100, :DELETE => false, :ORDER => 1, :choice => "Calexico")]
    @test [f.cleaned_data for f in Juango.deleted_forms(fs)] == [Dict(:votes => 900, :DELETE => true, :ORDER => 2, :choice => "Fergie")]
    fs = formset_factory(DfsDrink; can_delete = true, can_order = true)(Dict("form-0-name" => "", "form-0-DELETE" => "on", "form-TOTAL_FORMS" => 1,
                                                                             "form-INITIAL_FORMS" => 1, "form-MIN_NUM_FORMS" => 0, "form-MAX_NUM_FORMS" => 1))
    @test is_valid(fs) && Juango.ordered_forms(fs) == []

    # the formset's clean: its errors are the non-form errors
    dd = Dict("drinks-TOTAL_FORMS" => "2", "drinks-INITIAL_FORMS" => "0", "drinks-MIN_NUM_FORMS" => "0", "drinks-MAX_NUM_FORMS" => "0",
              "drinks-0-name" => "Gin and Tonic", "drinks-1-name" => "Gin and Tonic")
    fs = DfsDrinksFormSet(dd; prefix = "drinks")
    @test !is_valid(fs) && non_form_errors(fs) == ["You may only specify a drink once."]
    @test as_ul(non_form_errors(fs)).s == "<ul class=\"errorlist nonform\"><li>You may only specify a drink once.</li></ul>"
    fs = DfsDrinksFormSet(merge(dd, Dict("drinks-1-name" => "Bloody Mary")); prefix = "drinks")
    @test is_valid(fs) && non_form_errors(fs) == []
    # non_form_errors validates first
    fs = formset_factory(DfsChoice; clean = fs -> throw(Juango.ValidationError("This is a non-form error")))(
             Dict("choices-TOTAL_FORMS" => "1", "choices-INITIAL_FORMS" => "0"); auto_id = false, prefix = "choices")
    @test non_form_errors(fs) isa ErrorList && collect(non_form_errors(fs)) == ["This is a non-form error"]
    # an empty formset still runs clean
    E = formset_factory(DfsDrink; extra = 0, clean = fs -> throw(Juango.ValidationError("Clean method called")))
    @test !is_valid(E(Dict("form-INITIAL_FORMS" => "0", "form-TOTAL_FORMS" => "0"))) &&
          !is_valid(E(Dict("form-INITIAL_FORMS" => "0", "form-TOTAL_FORMS" => "1", "form-0-name" => "bah")))
end

@testset "django forms_tests: test_formsets (limits, management form, iteration, errors)" begin
    drink(i, v = "") = "<p><label for=\"id_form-$i-name\">Name:</label><input type=\"text\" name=\"form-$i-name\"" *
                       (isempty(v) ? "" : " value=\"$v\"") * " id=\"id_form-$i-name\"></p>"
    rendered(fs) = join([as_p(f).s for f in fs.forms], "\n")
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 3)()), drink(0) * drink(1) * drink(2))
    @test isempty(formset_factory(DfsDrink; extra = 3, max_num = 0)().forms)
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 5, max_num = 2)()), drink(0) * drink(1))
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 1, max_num = 2)()), drink(0))
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 1)(; initial = [Dict(:name => "Fernet and Coke")])), drink(0, "Fernet and Coke") * drink(1))
    @test isempty(formset_factory(DfsDrink; extra = 1, max_num = 0)().forms)
    # initial forms beat max_num
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 1, max_num = 0)(; initial = [Dict(:name => "Fernet and Coke"), Dict(:name => "Bloody Mary")])),
                  drink(0, "Fernet and Coke") * drink(1, "Bloody Mary"))
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 1, max_num = 2)(; initial = [Dict(:name => n) for n in ("Gin Tonic", "Bloody Mary", "Jack and Coke")])),
                  drink(0, "Gin Tonic") * drink(1, "Bloody Mary") * drink(2, "Jack and Coke"))
    @test html_eq(rendered(formset_factory(DfsDrink; extra = 3, max_num = 2)(; initial = [Dict(:name => "Gin Tonic")])), drink(0, "Gin Tonic") * drink(1))

    # absolute_max: twice the default max_num; a hard limit on the forms made
    fs = DfsDrinksFormSet(Dict("form-TOTAL_FORMS" => 2001, "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0"))
    @test !is_valid(fs) && non_form_errors(fs) == ["Please submit at most 1000 forms."] && fs.absolute_max == 2000
    A = formset_factory(DfsDrink; absolute_max = 3000)
    fs = A(Dict("form-TOTAL_FORMS" => "2001", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0"))
    @test is_valid(fs) && length(fs.forms) == 2001
    fs = A(Dict("form-TOTAL_FORMS" => "3001", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0"))
    @test !is_valid(fs) && length(fs.forms) == 3000 && non_form_errors(fs) == ["Please submit at most 1000 forms."]
    fs = formset_factory(DfsDrink; max_num = 30, absolute_max = 1000)(Dict("form-TOTAL_FORMS" => "1001", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0"))
    @test !is_valid(fs) && length(fs.forms) == 1000 && non_form_errors(fs) == ["Please submit at most 30 forms."]
    for mx in (nothing, 31)
        e = try formset_factory(DfsDrink; max_num = mx, absolute_max = 30) catch e; e end
        @test e isa ArgumentError && e.msg == "'absolute_max' must be greater or equal to 'max_num'."
    end
    # a hard limit too with a low max_num and absolute_max
    fs = formset_factory(DfsChoice; max_num = 1, absolute_max = 3)(Dict("choices-TOTAL_FORMS" => "4", "choices-INITIAL_FORMS" => "0", "choices-MIN_NUM_FORMS" => "0",
             "choices-MAX_NUM_FORMS" => "4", ("choices-$i-choice" => "c$i" for i in 0:3)..., ("choices-$i-votes" => "$i" for i in 0:3)...); prefix = "choices")
    @test length(fs.forms) == 3 && !is_valid(fs)

    # iteration and indexing
    fs = formset_factory(DfsChoice; extra = 3)()
    forms = collect(fs)
    @test forms == fs.forms && length(fs) == 3 && fs[1] === forms[1]
    @test_throws BoundsError fs[4]
    # with no forms it's still a formset
    @test isempty(formset_factory(DfsChoice; extra = 0)().forms)
    # a split date-time with a function initial
    fs = formset_factory(dfs_form([:when => SplitDateTimeField(initial = () -> Dates.now())]))(
             Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-0-when_0" => "1904-06-16", "form-0-when_1" => "15:51:33"))
    @test is_valid(fs)
    # deleted forms don't count for validate_max
    fs = formset_factory(dfs_form([:field => IntegerField()]); max_num = 1, validate_max = true, can_delete = true)(
             Dict("check-TOTAL_FORMS" => "2", "check-INITIAL_FORMS" => "0", "check-MAX_NUM_FORMS" => "1",
                  "check-0-field" => "200", "check-0-DELETE" => "", "check-1-field" => "50", "check-1-DELETE" => "on"); prefix = "check")
    @test is_valid(fs)
    # total_error_count
    for (data, n) in [([("Calexico", "100")], 0), ([("Calexico", "")], 1), ([("", "invalid")], 2), ([("Calexico", "100"), ("Calexico", "")], 1), ([("Calexico", ""), ("Calexico", "")], 2)]
        @test total_error_count(dfs_choices(data)) == n
    end
    two = Dict("choices-TOTAL_FORMS" => "2", "choices-INITIAL_FORMS" => "0", "choices-MAX_NUM_FORMS" => "2",
               "choices-0-choice" => "Zero", "choices-0-votes" => "0", "choices-1-choice" => "One", "choices-1-votes" => "1")
    FMax = formset_factory(DfsChoice; extra = 1, max_num = 1, validate_max = true)
    @test total_error_count(FMax(two; auto_id = false, prefix = "choices")) == 1
    @test total_error_count(FMax(merge(two, Dict("choices-1-votes" => "")); auto_id = false, prefix = "choices")) == 2
    # DELETE on every form, or only the initial ones (can_delete_extra = false)
    fs = formset_factory(DfsChoice; can_delete = true, extra = 2)()
    @test length(fs) == 2 && all(f -> any(x -> x.name === :DELETE, f.fields), fs.forms)
    NoX = formset_factory(DfsChoice; can_delete = true, can_delete_extra = false, extra = 2)
    has_del(f) = any(x -> x.name === :DELETE, f.fields)
    fs = NoX()
    @test length(fs) == 2 && !any(has_del, fs.forms)
    fs = NoX(; initial = [Dict(:choice => "Zero", :votes => "1")])
    @test length(fs) == 3 && has_del(fs.forms[1]) && !has_del(fs.forms[2]) && !has_del(fs.forms[3]) && !has_del(Juango.empty_form(fs))
    fs = NoX(Dict("form-0-choice" => "Zero", "form-0-votes" => "0", "form-0-DELETE" => "on", "form-1-choice" => "One", "form-1-votes" => "1",
                  "form-2-choice" => "", "form-2-votes" => "", "form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "1"); initial = [Dict(:choice => "Zero", :votes => "1")])
    @test is_valid(fs) && [f.cleaned_data for f in fs.forms] == [Dict(:choice => "Zero", :votes => 0, :DELETE => true), Dict(:choice => "One", :votes => 1), Dict()]
    @test is_deleted(fs, fs.forms[1]) && !is_deleted(fs, fs.forms[2]) && !is_deleted(fs, fs.forms[3])

    # repr doesn't validate
    @test repr(dfs_choices(; fs = formset_factory(DfsChoice; extra = 10))) == "<DfsChoiceFormSet: bound=False valid=Unknown total_forms=10>"
    @test repr(dfs_choices([])) == "<DfsChoiceFormSet: bound=True valid=Unknown total_forms=0>"
    fs = dfs_choices([("test", 1)])
    @test repr(fs) == "<DfsChoiceFormSet: bound=True valid=Unknown total_forms=1>" && !fs.validated
    is_valid(fs); @test repr(fs) == "<DfsChoiceFormSet: bound=True valid=True total_forms=1>"
    fs = dfs_choices([("test", "")]); is_valid(fs); @test repr(fs) == "<DfsChoiceFormSet: bound=True valid=False total_forms=1>"
    fs = dfs_choices([("test", "1"), ("test", "")]); is_valid(fs); @test repr(fs) == "<DfsChoiceFormSet: bound=True valid=False total_forms=2>"
    NF = formset_factory(DfsChoice; clean = fs -> throw(Juango.ValidationError("non-form error")), name = "ChoiceFormsetWithNonFormError")
    fs = dfs_choices([("test", "")]; fs = NF); is_valid(fs); @test repr(fs) == "<ChoiceFormsetWithNonFormError: bound=True valid=False total_forms=1>"

    # as_table, as_p, as_ul, as_div: the submitted management form, then the forms
    fs = DfsChoiceFormSet(Dict("choices-TOTAL_FORMS" => "1", "choices-INITIAL_FORMS" => "0", "choices-MIN_NUM_FORMS" => "0", "choices-MAX_NUM_FORMS" => "0",
                               "choices-0-choice" => "Calexico", "choices-0-votes" => "100"); auto_id = false, prefix = "choices")
    m = mgmt("choices", 1, 0, 0, 0)
    @test html_eq(as_table(fs), m * "<tr><th>Choice:</th><td><input type=\"text\" name=\"choices-0-choice\" value=\"Calexico\"></td></tr>" *
                                "<tr><th>Votes:</th><td><input type=\"number\" name=\"choices-0-votes\" value=\"100\"></td></tr>")
    @test html_eq(as_p(fs), m * "<p>Choice: <input type=\"text\" name=\"choices-0-choice\" value=\"Calexico\"></p><p>Votes: <input type=\"number\" name=\"choices-0-votes\" value=\"100\"></p>")
    @test html_eq(as_ul(fs), m * "<li>Choice: <input type=\"text\" name=\"choices-0-choice\" value=\"Calexico\"></li><li>Votes: <input type=\"number\" name=\"choices-0-votes\" value=\"100\"></li>")
    @test html_eq(as_div(fs), m * "<div>Choice: <input type=\"text\" name=\"choices-0-choice\" value=\"Calexico\"></div><div>Votes: <input type=\"number\" name=\"choices-0-votes\" value=\"100\"></div>")
end

@testset "django forms_tests: test_formsets (bound behaviour, empty formsets, all_valid)" begin
    AFS = formset_factory(DfsArticle)
    missing = "ManagementForm data is missing or has been tampered with. Missing fields: form-TOTAL_FORMS, form-INITIAL_FORMS. You may need to file a bug report if the issue persists."
    fs = AFS(Dict{String,Any}())
    @test !is_valid(fs) && non_form_errors(fs) == [missing] && Juango.errors(fs) == []
    fs = AFS(Dict("form-TOTAL_FORMS" => "two", "form-INITIAL_FORMS" => "one"))
    @test !is_valid(fs) && non_form_errors(fs) == [missing] && Juango.errors(fs) == []
    # (the management form renders what was submitted)
    @test occursin("name=\"form-TOTAL_FORMS\" value=\"two\" id=\"id_form-TOTAL_FORMS\"", Juango.management_form(fs).s)
    fs = AFS(Dict{String,Any}(); error_messages = Dict("missing_management_form" => "customized"))
    @test !is_valid(fs) && non_form_errors(fs) == ["customized"] && Juango.errors(fs) == []
    fs = AFS(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0"))
    @test Juango.initial_form_count(fs) == 0 && Juango.total_form_count(fs) == 1 && fs.forms[1].data !== nothing
    @test is_valid(fs) && is_valid(fs.forms[1]) && [f.cleaned_data for f in fs.forms] == [Dict()]
    fs = AFS(Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "0", "form-0-title" => "Test", "form-0-pub_date" => "1904-06-16",
                  "form-1-title" => "Test", "form-1-pub_date" => ""))
    @test !is_valid(fs) && Juango.errors(fs) == [Dict(), Dict(:pub_date => ["This field is required."])]
    # the empty form is unbound
    e1, e2 = Juango.empty_form(AFS()), Juango.empty_form(AFS(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-0-title" => "Test", "form-0-pub_date" => "1904-06-16")))
    @test e1.data === nothing && e2.data === nothing && as_p(e1).s == as_p(e2).s
    # an empty formset is multipart if its form would be
    @test is_multipart(formset_factory(dfs_form([:file => FileField()]); extra = 0)())
    # all_valid validates every formset
    ok = Dict("choices-TOTAL_FORMS" => "2", "choices-INITIAL_FORMS" => "0", "choices-MIN_NUM_FORMS" => "0",
              "choices-0-choice" => "Zero", "choices-0-votes" => "0", "choices-1-choice" => "One", "choices-1-votes" => "1")
    f1, f2 = (DfsChoiceFormSet(ok; auto_id = false, prefix = "choices") for _ in 1:2)
    @test all_valid((f1, f2)) && Juango.errors(f1) == [Dict(), Dict()] && Juango.errors(f2) == [Dict(), Dict()]
    bad = merge(ok, Dict("choices-0-votes" => "", "choices-1-votes" => ""))
    f1, f2 = (DfsChoiceFormSet(bad; auto_id = false, prefix = "choices") for _ in 1:2)
    @test !all_valid((f1, f2))
    @test Juango.errors(f1) == [Dict(:votes => ["This field is required."]) for _ in 1:2] && Juango.errors(f2) == Juango.errors(f1)
end

# ---- Django's forms_tests/tests/test_error_messages.py: error_messages replace each message, with its parameters
@testset "django forms_tests: test_error_messages" begin
    lenmsgs = Dict("required" => "REQUIRED", "invalid" => "INVALID", "min_length" => "LENGTH %(show_value)s, MIN LENGTH %(limit_value)s",
                   "max_length" => "LENGTH %(show_value)s, MAX LENGTH %(limit_value)s")
    f = CharField(min_length = 5, max_length = 10, error_messages = lenmsgs)
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "1234") == ["LENGTH 4, MIN LENGTH 5"] && clean_errors(f, "12345678901") == ["LENGTH 11, MAX LENGTH 10"]
    nums = Dict("required" => "REQUIRED", "invalid" => "INVALID", "min_value" => "MIN VALUE IS %(limit_value)s", "max_value" => "MAX VALUE IS %(limit_value)s")
    for f in (IntegerField(min_value = 5, max_value = 10, error_messages = nums), FloatField(min_value = 5, max_value = 10, error_messages = nums),
              DecimalField(min_value = 5, max_value = 10, error_messages = nums))
        @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "abc") == ["INVALID"] && clean_errors(f, "4") == ["MIN VALUE IS 5"] && clean_errors(f, "11") == ["MAX VALUE IS 10"]
    end
    f2 = DecimalField(max_digits = 4, decimal_places = 2, error_messages = merge(nums, Dict("max_digits" => "MAX DIGITS IS %(max)s",
             "max_decimal_places" => "MAX DP IS %(max)s", "max_whole_digits" => "MAX DIGITS BEFORE DP IS %(max)s")))
    @test clean_errors(f2, "123.45") == ["MAX DIGITS IS 4"] && clean_errors(f2, "1.234") == ["MAX DP IS 2"] && clean_errors(f2, "123.4") == ["MAX DIGITS BEFORE DP IS 2"]
    ri = Dict("required" => "REQUIRED", "invalid" => "INVALID")
    for f in (DateField(error_messages = ri), TimeField(error_messages = ri), DateTimeField(error_messages = ri))
        @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "abc") == ["INVALID"]
    end
    f = RegexField(r"^[0-9]+$"; min_length = 5, max_length = 10, error_messages = lenmsgs)
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "abcde") == ["INVALID"] && clean_errors(f, "1234") == ["LENGTH 4, MIN LENGTH 5"] &&
          clean_errors(f, "12345678901") == ["LENGTH 11, MAX LENGTH 10"]
    f = EmailField(min_length = 8, max_length = 10, error_messages = lenmsgs)
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "abcdefgh") == ["INVALID"] && clean_errors(f, "a@b.com") == ["LENGTH 7, MIN LENGTH 8"] &&
          clean_errors(f, "aye@bee.com") == ["LENGTH 11, MAX LENGTH 10"]
    f = FileField(error_messages = Dict("required" => "REQUIRED", "invalid" => "INVALID", "missing" => "MISSING", "empty" => "EMPTY FILE"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "abc") == ["INVALID"] && clean_errors(f, UploadedFile("name", "")) == ["EMPTY FILE"]
    f = URLField(max_length = 17, error_messages = Dict("required" => "REQUIRED", "invalid" => "INVALID", "max_length" => "\"%(value)s\" has more than %(limit_value)d characters."))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "abc.c") == ["INVALID"]
    @test clean_errors(f, "djangoproject.com") == ["\"https://djangoproject.com\" has more than 17 characters."]
    @test clean_errors(BooleanField(error_messages = Dict("required" => "REQUIRED")), "") == ["REQUIRED"]
    f = ChoiceField([("a", "aye")]; error_messages = Dict("required" => "REQUIRED", "invalid_choice" => "%(value)s IS INVALID CHOICE"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "b") == ["b IS INVALID CHOICE"]
    f = MultipleChoiceField([("a", "aye")]; error_messages = Dict("required" => "REQUIRED", "invalid_choice" => "%(value)s IS INVALID CHOICE", "invalid_list" => "NOT A LIST"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "b") == ["NOT A LIST"] && clean_errors(f, ["b"]) == ["b IS INVALID CHOICE"]
    f = SplitDateTimeField(error_messages = Dict("required" => "REQUIRED", "invalid_date" => "INVALID DATE", "invalid_time" => "INVALID TIME"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, ["a", "b"]) == ["INVALID DATE", "INVALID TIME"]
    f = GenericIPAddressField(error_messages = Dict("required" => "REQUIRED", "invalid" => "INVALID IP ADDRESS"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "127.0.0") == ["INVALID IP ADDRESS"]

    # errors render as Django's lists (a custom ErrorList class: Juango has none to subclass)
    f = Form([:first_name => CharField(max_length = nothing), :last_name => CharField(max_length = nothing), :birthday => DateField()];
             data = Dict("first_name" => "John"), clean = f -> throw(Juango.ValidationError("I like to be awkward.")))
    t(src, f) = render(Template(src), Dict{String,Any}("form" => f))
    @test html_eq(t("{{ form.last_name.errors }}", f), "<ul class=\"errorlist\" id=\"id_last_name_error\"><li>This field is required.</li></ul>")
    @test html_eq(t("{{ form.non_field_errors }}", f), "<ul class=\"errorlist nonfield\"><li>I like to be awkward.</li></ul>")
    # the messages are escaped where they're shown
    f = Form([:field => ChoiceField([("one", "One")])]; data = Dict("field" => "<script>"))
    @test html_eq(t("{{ form.errors }}", f), "<ul class=\"errorlist\"><li>field<ul class=\"errorlist\" id=\"id_field_error\">" *
                                             "<li>Select a valid choice. &lt;script&gt; is not one of the available choices.</li></ul></li></ul>")
    f = Form([:field => MultipleChoiceField([("one", "One")])]; data = Dict("field" => ["<script>"]))
    @test html_eq(t("{{ form.errors }}", f), "<ul class=\"errorlist\"><li>field<ul class=\"errorlist\" id=\"id_field_error\">" *
                                             "<li>Select a valid choice. &lt;script&gt; is not one of the available choices.</li></ul></li></ul>")
    f = Form([:field => ModelMultipleChoiceField(Author)]; data = Dict("field" => ["<script>"]))
    @test html_eq(t("{{ form.errors }}", f), "<ul class=\"errorlist\"><li>field<ul class=\"errorlist\" id=\"id_field_error\">" *
                                             "<li>“&lt;script&gt;” is not a valid value.</li></ul></li></ul>")

    # model choices
    a = create(Author; name = "DEM a")
    f = ModelChoiceField(filter(Author; name = "DEM a"); error_messages = Dict("required" => "REQUIRED", "invalid_choice" => "INVALID CHOICE"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, string(a.id + 1000)) == ["INVALID CHOICE"]
    f = ModelMultipleChoiceField(filter(Author; name = "DEM a"); error_messages = Dict("required" => "REQUIRED", "invalid_choice" => "%(value)s IS INVALID CHOICE",
                                                                                       "invalid_list" => "NOT A LIST OF VALUES"))
    @test clean_errors(f, "") == ["REQUIRED"] && clean_errors(f, "3") == ["NOT A LIST OF VALUES"] && clean_errors(f, [string(a.id + 1000)]) == ["$(a.id + 1000) IS INVALID CHOICE"]
    f = ModelChoiceField(Author; error_messages = Dict("invalid_choice" => "\"%(value)s\" is not one of the available choices."))
    @test clean_errors(f, "invalid") == ["\"invalid\" is not one of the available choices."]
    delete!(a)
end

@testset "django forms_tests: test_validators" begin
    # all errors get reported, from validators in a tuple or a vector
    user_form(data) = Form([
        :full_name => CharField(max_length = 50, validators = [validate_integer, validate_email]),
        :string => CharField(max_length = 50, validators = [RegexValidator("^[a-zA-Z]*\$"; message = "Letters only.")]),
        :ignore_case_string => CharField(max_length = 50, validators = [RegexValidator("^[a-z]*\$"; message = "Letters only.", flags = "i")]),
    ]; data)
    form = user_form(Dict("full_name" => "not int nor mail", "string" => "2 is not correct", "ignore_case_string" => "IgnORE Case strIng"))
    @test length(clean_errors(form.fields[1], "not int nor mail")) == 2
    @test !is_valid(form)
    @test form.errors[:string] == ["Letters only."]
    @test form.errors[:ignore_case_string] == ["Letters only."]     # (its spaces don't match either)
    form = Form([:full_name => CharField(max_length = 50, validators = (validate_integer, validate_email))];
                data = Dict("full_name" => "not int nor mail"))
    @test !is_valid(form) && form.errors[:full_name] == ["Enter a valid integer.", "Enter a valid email address."]

    # %(value)s in a validator's custom message, on a CharField
    for (v, value, code) in [
            (validate_integer, "-42.5", "invalid"), (validate_email, "a", "invalid"), (validate_email, "a@b\n.com", "invalid"),
            (validate_email, "a\n@b.com", "invalid"), (validate_slug, "你 好", "invalid"), (validate_unicode_slug, "你 好", "invalid"),
            (validate_ipv4_address, "256.1.1.1", "invalid"), (validate_ipv6_address, "1:2", "invalid"),
            (validate_ipv46_address, "256.1.1.1", "invalid"), (validate_comma_separated_integer_list, "a,b,c", "invalid"),
            (int_list_validator(), "-1,2,3", "invalid"), (MaxLengthValidator(10), "x"^11, "max_length"),
            (MinLengthValidator(10), "x"^9, "min_length"), (URLValidator(), "no_scheme", "invalid"),
            (URLValidator(), "http://test[.com", "invalid"), (URLValidator(), "http://[::1:2::3]/", "invalid"),
            (URLValidator(), "http://" * join(fill("a"^35, 9), "."), "invalid"), (RegexValidator("[0-9]+"), "xxxxxx", "invalid")]
        f = Form([:field => CharField(max_length = nothing, validators = [v], error_messages = Dict(code => "%(value)s"))]; data = Dict("field" => value))
        @test (value, is_valid(f), f.errors) == (value, false, Dict(:field => [value]))
    end
    f = Form([:field => CharField(error_messages = Dict("null_characters_not_allowed" => "%(value)s"))]; data = Dict("field" => "a\0b"))
    @test !is_valid(f) && f.errors == Dict(:field => ["a\0b"])
    # on an IntegerField
    for (v, value, code) in [(MaxValueValidator(0), 1, "max_value"), (MinValueValidator(0), -1, "min_value"), (URLValidator(), "1", "invalid")]
        f = Form([:field => IntegerField(validators = [v], error_messages = Dict(code => "%(value)s"))]; data = Dict("field" => value))
        @test !is_valid(f) && f.errors == Dict(:field => [string(value)])
    end
    # on a DecimalField
    for (value, code) in [("NaN", "invalid"), ("123", "max_digits"), ("0.12", "max_decimal_places"), ("12", "max_whole_digits")]
        f = Form([:field => DecimalField(max_digits = 2, decimal_places = 1, error_messages = Dict(code => "%(value)s"))];
                 data = Dict("field" => value))
        @test !is_valid(f) && f.errors == Dict(:field => [value])
    end
    # on a FileField
    f = Form([:field => FileField(validators = [validate_image_file_extension], error_messages = Dict("invalid_extension" => "%(value)s"))];
             data = Dict{String,Any}(), files = Dict{String,Any}("field" => UploadedFile("myfile.txt", "abc")))
    @test !is_valid(f) && f.errors == Dict(:field => ["myfile.txt"])
end

struct DfuVeryBadError end
Base.print(io::IO, ::DfuVeryBadError) = print(io, "A very bad error.")

@testset "django forms_tests: test_utils" begin
    # flatatt
    @test flatatt(Dict("id" => "header")) == " id=\"header\""
    @test flatatt(Dict("class" => "news", "title" => "Read this")) == " class=\"news\" title=\"Read this\""
    @test flatatt(Dict("class" => "news", "title" => "Read this", "required" => "required")) == " class=\"news\" required=\"required\" title=\"Read this\""
    @test flatatt(Dict("class" => "news", "title" => "Read this", "required" => true)) == " class=\"news\" title=\"Read this\" required"
    @test flatatt(Dict("class" => "news", "title" => "Read this", "required" => false)) == " class=\"news\" title=\"Read this\""
    @test flatatt(Dict("class" => nothing)) == "" && flatatt(Dict()) == ""
    attrs = Dict{String,Any}("foo" => "bar", "true" => true, "false" => false)
    attrs_copy = copy(attrs)
    @test flatatt(attrs) == " foo=\"bar\" true" && attrs == attrs_copy && flatatt(attrs) == flatatt(attrs)

    # ValidationError messages in an ErrorList
    ul(e) = Juango.__html__(ErrorList(e))
    @test html_eq(ul(ValidationError("There was an error.").messages), "<ul class=\"errorlist\"><li>There was an error.</li></ul>")
    @test html_eq(ul(ValidationError("Not π.").messages), "<ul class=\"errorlist\"><li>Not π.</li></ul>")
    @test html_eq(ul(ValidationError(gettext_lazy("Error.")).messages), "<ul class=\"errorlist\"><li>Error.</li></ul>")
    @test html_eq(ul(ValidationError(["Error one.", "Error two."]).messages),
                  "<ul class=\"errorlist\"><li>Error one.</li><li>Error two.</li></ul>")
    @test html_eq(ul(sort(ValidationError(Dict("error_1" => "1. Error one.", "error_2" => "2. Error two.")).messages)),
                  "<ul class=\"errorlist\"><li>1. Error one.</li><li>2. Error two.</li></ul>")
    @test html_eq(ul(sort(ValidationError(["1. First error.", "2. Not π.", gettext_lazy("3. Error."),
                                           Dict("error_1" => "4. First dict error.", "error_2" => "5. Second dict error.")]).messages)),
                  "<ul class=\"errorlist\"><li>1. First error.</li><li>2. Not π.</li><li>3. Error.</li>" *
                  "<li>4. First dict error.</li><li>5. Second dict error.</li></ul>")
    @test html_eq(ul(ValidationError([DfuVeryBadError()]).messages), "<ul class=\"errorlist\"><li>A very bad error.</li></ul>")
    # escapes what isn't marked safe
    example = "Example of link: <a href=\"http://www.example.com/\">example</a>"
    escaped = "Example of link: &lt;a href=&quot;http://www.example.com/&quot;&gt;example&lt;/a&gt;"
    @test html_eq(ul([example]), "<ul class=\"errorlist\"><li>$escaped</li></ul>")
    @test html_eq(ul([mark_safe(example)]), "<ul class=\"errorlist\"><li>$example</li></ul>")
    @test html_eq(Juango.__html__(ErrorDict(Dict("name" => example))), "<ul class=\"errorlist\"><li>name<ul class=\"errorlist\"><li>$escaped</li></ul></li></ul>")
    @test html_eq(Juango.__html__(ErrorDict(Dict("name" => mark_safe(example)))), "<ul class=\"errorlist\"><li>name<ul class=\"errorlist\"><li>$example</li></ul></li></ul>")

    # copies
    e = ErrorList([ValidationError("message %(i)s"; params = Dict("i" => 1)), ValidationError("message %(i)s"; params = Dict("i" => 2))])
    @test e == copy(e) == ["message 1", "message 2"]
    e = ErrorList(; error_class = "woopsies")
    @test copy(e) == e
    e = ErrorDict()
    e["__all__"] = ErrorList([ValidationError("message %(i)s"; params = Dict("i" => 1)), ValidationError("message %(i)s"; params = Dict("i" => 2))])
    @test e == copy(e) == deepcopy(e)
    e = ErrorDict()
    e["username"] = "Invalid username."
    @test e isa AbstractDict && Juango.__html__(e) == as_ul(e).s
    @test Juango.__html__(ErrorList(["Invalid username."])) == as_ul(ErrorList(["Invalid username."])).s
    # an ErrorDict is JSON
    mins = ErrorList([ValidationError("Ensure this value is greater than or equal to 0.")])
    e = ErrorDict(Dict("__all__" => ErrorList([ValidationError("Sorry this form only works on leap days.")]),
                       "name" => ErrorList([ValidationError("This field is required.")])))
    e["renderer"] = ErrorList([ValidationError("Select a valid choice. That choice is not one of the available choices.")])
    @test JSON.parse(JSON.json(e)) == Dict("__all__" => ["Sorry this form only works on leap days."], "name" => ["This field is required."],
                                           "renderer" => ["Select a valid choice. That choice is not one of the available choices."])
    @test JSON.parse(JSON.json(Dict("date" => [ErrorDict(Dict("day" => mins, "month" => mins, "year" => mins))]))) ==
          Dict("date" => [Dict(k => ["Ensure this value is greater than or equal to 0."] for k in ("day", "month", "year"))])
    # (RenderableMixin and RenderableFieldMixin: no counterpart; Juango renders with functions)

    @test pretty_name("john_doe") == "John doe" && pretty_name(nothing) == "" && pretty_name("") == ""
end

# --- tests/model_forms/models.py -----------------------------------------------------------------------
@model struct MfPerson
    name = CharField(max_length = 100)
    Meta(table = "mf_person")
end
@model struct MfCategory
    name = CharField(max_length = 20)
    slug = SlugField(max_length = 20)
    url = CharField(max_length = 40, verbose_name = "The URL")
    Meta(table = "mf_category", ordering = ["pk"])
end
Base.show(io::IO, c::MfCategory) = print(io, c.name)
@model struct MfWriter
    name = CharField(max_length = 50, help_text = "Use both first and last names.")
    archived = BooleanField(default = false, editable = false)
    Meta(table = "mf_writer", ordering = ["name"])
end
Base.show(io::IO, w::MfWriter) = print(io, w.name)
# (Django's WriterManager: archived writers aren't in the default queryset)
Juango.default_queryset(::Type{MfWriter}) = filter(base_objects(MfWriter); archived = false)
@model struct MfArticle
    headline = CharField(max_length = 50)
    slug = SlugField()
    pub_date = DateField()
    created = DateField(editable = false, auto_now_add = true)
    writer = ForeignKey(MfWriter, on_delete = :CASCADE)
    article = TextField()
    categories = ManyToManyField(MfCategory; blank = true)
    status = PositiveIntegerField(choices = [(1, "Draft"), (2, "Pending"), (3, "Live")], blank = true, null = true)
    Meta(table = "mf_article")
end
@model struct MfPublicationDefaults
    title = CharField(max_length = 30)
    date_published = DateField(default = () -> Dates.today())
    datetime_published = DateTimeField(default = DateTime(2000, 1, 1))
    mode = CharField(max_length = 2, choices = [("di", "direct"), ("de", "delayed")], default = () -> "di")
    category = IntegerField(choices = [(1, "Games"), (2, "Comics"), (3, "Novel")], default = () -> 3)
    active = BooleanField(default = true)
    file = FileField(default = "default.txt")
    Meta(table = "mf_publicationdefaults")
end
@model struct MfCharacter
    username = CharField(max_length = 100)
    last_action = DateTimeField()
    Meta(table = "mf_character")
end
Base.show(io::IO, c::MfCharacter) = print(io, c.username)
@model struct MfStudent
    character = ForeignKey(MfCharacter, on_delete = :CASCADE)
    study = CharField(max_length = 30)
    Meta(table = "mf_student")
end
@model struct MfAward
    name = CharField(max_length = 30)
    character = ForeignKey(MfCharacter, on_delete = :SET_NULL, blank = false, null = true)
    Meta(table = "mf_award")
end
@model struct MfBook
    title = CharField(max_length = 40)
    author = ForeignKey(MfWriter, on_delete = :SET_NULL, blank = true, null = true)
    special_id = IntegerField(blank = true, null = true, unique = true)
    Meta(table = "mf_book", unique_together = [(:title, :author)], verbose_name = "book")
end
@model struct MfPrice
    price = DecimalField(max_digits = 10, decimal_places = 2)
    quantity = PositiveIntegerField()
    Meta(table = "mf_price", unique_together = [(:price, :quantity)], verbose_name = "price")
end
@model struct MfNullableUniqueCharFieldModel
    codename = CharField(max_length = 50, blank = true, null = true, unique = true)
    email = EmailField(blank = true, null = true)
    slug = SlugField(blank = true, null = true)
    url = URLField(blank = true, null = true)
    Meta(table = "mf_nullableuniquecharfieldmodel")
end
redirect_stdout(devnull) do
    ms = [MfPerson, MfCategory, MfWriter, MfArticle, through(MfArticle, :categories), MfPublicationDefaults, MfCharacter,
          MfStudent, MfAward, MfBook, MfPrice, MfNullableUniqueCharFieldModel]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

mf_names(f) = [x.name for x in f.fields]
# (Django's ModelForm classes are functions here: Meta's options are ModelForm's keywords, declared fields extra_fields)
MfCategoryForm(data = nothing; kw...) = ModelForm(MfCategory; data, fields = "__all__", kw...)
MfCustomWriterForm(data = nothing; kw...) = ModelForm(MfWriter; data, fields = "__all__", extra_fields = [:name => CharField(required = false)], kw...)
not_required(names...) = f -> (f.name in names && (f.blank = true); f)
unknown_fields(f) = try f(); "" catch e; e isa Juango.LookupError ? e.msg : rethrow() end

@testset "django model_forms: ModelFormBaseTest (fields)" begin
  port_block() do
    @test mf_names(MfCategoryForm()) == [:name, :slug, :url]                                     # test_base_form
    # (test_no_model_class, test_invalid_meta_model: ModelForm takes its model as an argument)
    @test isempty(fields_for_model(MfPerson; fields = ()))                                        # test_empty_fields_to_fields_for_model
    @test isempty(ModelForm(MfPerson; fields = ()).fields)                                        # test_empty_fields_on_modelform
    form = modelform_factory(MfPerson; fields = "__all__")(Dict("name" => "John Doe"))
    @test is_valid(form) && construct_instance(form, MfPerson(); fields = ()).name == ""         # test_empty_fields_to_construct_instance
    # test_blank_with_null_foreign_key_field
    char = create(MfCharacter; username = "user", last_action = DateTime(2020, 1, 1))
    student_form(data) = ModelForm(MfStudent; data, fields = "__all__", formfield_callback = not_required(:character))
    @test is_valid(student_form(Dict("study" => "Engineering")))
    f2 = student_form(Dict("study" => "Engineering", "character" => string(char.id)))
    @test is_valid(f2) && save!(f2).character.id == char.id
    # test_blank_false_with_null_true_foreign_key_field
    award = create(MfAward; name = "Best sprinter", character = char)
    form = ModelForm(MfAward; data = Dict("name" => "Best tester", "character" => ""), instance = award, fields = "__all__",
                     formfield_callback = not_required(:character))
    @test is_valid(form) && save!(form).character === nothing
    # test_blank_foreign_key_with_radio, test_non_blank_foreign_key_with_radio
    writer = create(MfWriter; name = "Joe Doe")
    form = ModelForm(MfBook; fields = [:author], widgets = Dict(:author => :radio))
    @test [(w.value, w.label) for w in form[:author]] == [("", "---------"), (string(writer.id), "Joe Doe")]
    form = ModelForm(MfAward; fields = [:character], widgets = Dict(:character => :radio))
    @test [(w.value, w.label) for w in form[:character]] == [(string(char.id), "user")]
    # test_save_blank_false_with_required_false
    obj = create(MfWriter; name = "test")
    form = MfCustomWriterForm(Dict("name" => ""); instance = obj)
    @test is_valid(form) && save!(form).name == ""
    # test_save_blank_null_unique_charfield_saves_null: twice, so no unique constraint is violated
    for _ in 1:2
        form = modelform_factory(MfNullableUniqueCharFieldModel; fields = "__all__")(Dict("codename" => "", "email" => "", "slug" => "", "url" => ""))
        @test is_valid(form)
        save!(form)
        @test all(n -> getproperty(form.instance, n) === nothing, (:codename, :email, :slug, :url))
    end
    # (test_missing_fields_attribute: Juango's ModelForm takes all the editable fields when neither is given)
    @test mf_names(MfCategoryForm(; extra_fields = [:some_extra_field => BooleanField()])) == [:name, :slug, :url, :some_extra_field]   # test_extra_fields
    # test_extra_field_model_form, test_extra_field_modelform_factory, test_limit_nonexistent_field
    @test unknown_fields(() -> ModelForm(MfPerson; fields = (:name, Symbol("no-field")), extra_fields = [:age => IntegerField()])) ==
          "Unknown field(s) (no-field) specified for MfPerson"
    @test unknown_fields(() -> modelform_factory(MfPerson; fields = [Symbol("no-field"), :name])) == "Unknown field(s) (no-field) specified for MfPerson"
    @test unknown_fields(() -> ModelForm(MfCategory; fields = [:nonexistent])) == "Unknown field(s) (nonexistent) specified for MfCategory"
    @test mf_names(ModelForm(MfPerson; fields = (:name, :age), extra_fields = [:age => IntegerField()])) == [:name, :age]  # test_extra_declared_field_model_form
    # test_replace_field (and variants 2 and 3: the declared field is there whatever fields says)
    for fields in ("__all__", [:url], Symbol[])
        @test ModelForm(MfCategory; fields, extra_fields = [:url => BooleanField()])[:url].field.kind === :bool
    end
    @test is_valid(ModelForm(MfWriter; data = Dict("name" => "Richard Lockridge"), fields = "__all__",
                             extra_fields = [:book => CharField(required = false)]))              # test_override_field
    # test_limit_fields_with_string, test_exclude_fields_with_string
    @test (try ModelForm(MfCategory; fields = "url"); false catch e; e isa ArgumentError && occursin("cannot be a string", e.msg) end)
    @test (try ModelForm(MfCategory; exclude = "url"); false catch e; e isa ArgumentError && occursin("cannot be a string", e.msg) end)
    @test mf_names(ModelForm(MfCategory; exclude = [:url])) == [:name, :slug]                    # test_exclude_fields
    @test mf_names(ModelForm(MfCategory; exclude = [:nonexistent])) == [:name, :slug, :url]      # test_exclude_nonexistent_field
    # test_exclude_and_validation: the instance isn't valid (quantity is required) but the form is
    form = ModelForm(MfPrice; data = Dict("price" => "6.00"), exclude = (:quantity,))
    @test is_valid(form)
    price = save!(form; commit = false)
    @test get(full_clean(price), :quantity, String[]) == ["This field cannot be null."]
    form = ModelForm(MfPrice; data = Dict("price" => "6.00"), fields = (:price,))
    @test is_valid(form)
    # (Django's form.instance is made by is_valid; Juango's by save!(form; commit = false))
    price = save!(form; commit = false)
    @test price.price == Decimal("6.00") && price.quantity === nothing && price.id === nothing
    @test mf_names(ModelForm(MfCategory; fields = [:name, :url], exclude = [:url])) == [:name]   # test_confused_form
    # test_mixmodel_form, test_article_form, test_bad_form, test_subcategory_form
    @test mf_names(ModelForm(MfArticle; fields = "__all__")) == [:headline, :slug, :pub_date, :writer, :article, :categories, :status]
    # test_subclassmeta_form
    @test html_eq(as_div(ModelForm(MfCategory; exclude = [:url], extra_fields = [:checkbox => BooleanField()])),
                  "<div><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" maxlength=\"20\" required id=\"id_name\"></div>" *
                  "<div><label for=\"id_slug\">Slug:</label><input type=\"text\" name=\"slug\" maxlength=\"20\" required id=\"id_slug\"></div>" *
                  "<div><label for=\"id_checkbox\">Checkbox:</label><input type=\"checkbox\" name=\"checkbox\" required id=\"id_checkbox\"></div>")
    # test_orderfields_form, test_orderfields2_form
    form = ModelForm(MfCategory; fields = [:url, :name])
    @test mf_names(form) == [:url, :name]
    @test html_eq(as_div(form), "<div><label for=\"id_url\">The URL:</label><input type=\"text\" name=\"url\" maxlength=\"40\" required id=\"id_url\"></div>" *
                                "<div><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" maxlength=\"20\" required id=\"id_name\"></div>")
    @test mf_names(ModelForm(MfCategory; fields = [:slug, :url, :name], exclude = [:url])) == [:slug, :name]
  end
end

@testset "django model_forms: ModelFormBaseTest (defaults)" begin
    pub_form(data = Dict{String,Any}(); fields = (:mode,), kw...) = ModelForm(MfPublicationDefaults; data, fields, kw...)
    optional_mode = [:mode => CharField(max_length = 255, required = false)]
    # test_default_populated_on_optional_field: data without the field takes the model's default; blank data doesn't
    mf1 = pub_form(; extra_fields = optional_mode)
    @test is_valid(mf1) && isempty(mf1.errors) && save!(mf1; commit = false).mode == "di"
    mf2 = pub_form(Dict("mode" => ""); extra_fields = optional_mode)
    @test is_valid(mf2) && save!(mf2; commit = false).mode == ""
    # test_default_not_populated_on_non_empty_value_in_cleaned_data
    mocked(v) = f -> (f.cleaned_data[:mode] = v; f.cleaned_data)
    @test save!(pub_form(; extra_fields = optional_mode, clean = mocked("de")); commit = false).mode == "de"
    for empty_value in (nothing, "", [], (), Dict())
        @test save!(pub_form(; extra_fields = optional_mode, clean = mocked(empty_value)); commit = false).mode == "di"
    end
    # test_default_not_populated_on_optional_checkbox_input: an unchecked checkbox isn't sent
    mf1 = pub_form(; fields = (:active,))
    @test is_valid(mf1) && save!(mf1; commit = false).active === false
    # test_default_not_populated_on_checkboxselectmultiple: nor are unchecked checkboxes
    mf1 = pub_form(; extra_fields = [:mode => CharField(required = false, widget = :checkboxes)])
    @test is_valid(mf1) && save!(mf1; commit = false).mode == ""
    # test_prefixed_form_with_default_field
    @test save!(pub_form(Dict("form-prefix-mode" => "de"); prefix = "form-prefix"); commit = false).mode == "de"
    # test_default_splitdatetime_field
    split_dt = [:datetime_published => SplitDateTimeField(required = false)]
    @test save!(pub_form(; fields = (:datetime_published,), extra_fields = split_dt); commit = false).datetime_published == DateTime(2000, 1, 1)
    @test save!(pub_form(Dict("datetime_published_0" => "2010-01-01", "datetime_published_1" => "0:00:00"); fields = (:datetime_published,),
                         extra_fields = split_dt); commit = false).datetime_published == DateTime(2010, 1, 1)
    # test_default_filefield
    @test save!(pub_form(; fields = (:file,)); commit = false).file.name == "default.txt"
    @test save!(pub_form(; fields = (:file,), files = Dict{String,Any}("file" => UploadedFile("name", "foo"))); commit = false).file.name == "name"
    # test_default_selectdatewidget
    sdw = [:date_published => DateField(required = false, widget = SelectDateWidget())]
    @test save!(pub_form(; fields = (:date_published,), extra_fields = sdw); commit = false).date_published == Dates.today()
    @test save!(pub_form(Dict("date_published_year" => "2010", "date_published_month" => "1", "date_published_day" => "1");
                         fields = (:date_published,), extra_fields = sdw); commit = false).date_published == Date(2010, 1, 1)
end

@testset "django model_forms: TestFieldOverridesByFormMeta, ValidationTest" begin
    overrides(data = nothing) = ModelForm(MfCategory; data, fields = [:name, :url, :slug],
        widgets = Dict(:name => :textarea, :url => Widget(:text; attrs = Dict("class" => "url"))),
        labels = Dict(:name => "Title"), help_texts = Dict(:slug => "Watch out! Letters, numbers, underscores and hyphens only."),
        error_messages = Dict(:slug => Dict("invalid" => "Didn't you read the help text? We said letters, numbers, underscores and hyphens only!")),
        field_classes = Dict(:url => URLField))
    form = overrides()
    @test html_eq(w(form[:name]), "<textarea id=\"id_name\" rows=\"10\" cols=\"40\" name=\"name\" maxlength=\"20\" required></textarea>")
    @test html_eq(w(form[:url]), "<input id=\"id_url\" type=\"text\" class=\"url\" name=\"url\" maxlength=\"40\" required>")
    @test html_eq(w(form[:slug]), "<input id=\"id_slug\" type=\"text\" name=\"slug\" maxlength=\"20\" aria-describedby=\"id_slug_helptext\" required>")
    @test html_eq(label_tag(form[:name]), "<label for=\"id_name\">Title:</label>") && html_eq(label_tag(form[:url]), "<label for=\"id_url\">The URL:</label>") &&
          html_eq(label_tag(form[:slug]), "<label for=\"id_slug\">Slug:</label>")
    @test legend_tag(form[:name]) == "<legend>Title:</legend>" && legend_tag(form[:url]) == "<legend>The URL:</legend>" &&
          legend_tag(form[:slug]) == "<legend>Slug:</legend>"
    @test form[:slug].field.help_text == "Watch out! Letters, numbers, underscores and hyphens only."
    form = overrides(Dict("name" => "Category", "url" => "http://www.example.com/category/", "slug" => "!%#*@"))
    @test !is_valid(form) && form.errors == Dict(:slug => ["Didn't you read the help text? We said letters, numbers, underscores and hyphens only!"])
    @test Juango.getfield_meta(MfCategory, :url).kind === :char && overrides()[:url].field.kind === :url    # test_field_type_overrides
    # ValidationTest: a declared field replacing the model's isn't validated as the model's
    optional_url = [:url => CharField(required = false)]
    @test is_valid(ModelForm(MfCategory; data = Dict("name" => "some name", "slug" => "some-slug"), fields = (:name, :slug), extra_fields = optional_url))
    @test is_valid(ModelForm(MfCategory; data = Dict("name" => "some name", "slug" => "some-slug"), exclude = [:url], extra_fields = optional_url))
    @test is_valid(MfCustomWriterForm(Dict{String,Any}()))                                         # test_notrequired_overrides_notblank
end

@model struct MfProduct
    slug = SlugField(unique = true)
    Meta(table = "mf_product", verbose_name = "product")
end
@model struct MfTriple
    left = IntegerField()
    middle = IntegerField()
    right = IntegerField()
    Meta(table = "mf_triple", unique_together = [(:left, :middle), (:middle, :right)])
end
# (Django's DerivedBook inherits Book and the abstract BookXtra; a Julia struct has one supertype, so BookXtra's fields are here)
@model struct MfDerivedBook <: MfBook
    isbn = CharField(max_length = 16, unique = true)
    suffix1 = IntegerField(blank = true, default = 0)
    suffix2 = IntegerField(blank = true, default = 0)
    Meta(table = "mf_derivedbook", unique_together = [(:suffix1, :suffix2)], verbose_name = "derived book")
end
@model struct MfExplicitPK
    key = CharField(max_length = 20, primary_key = true)
    desc = CharField(max_length = 20, blank = true, unique = true)
    Meta(table = "mf_explicitpk", unique_together = [(:key, :desc)], verbose_name = "explicit pk")
end
@model struct MfPost
    title = CharField(max_length = 50, unique_for_date = :posted, blank = true)
    slug = CharField(max_length = 50, unique_for_year = :posted, blank = true)
    subtitle = CharField(max_length = 50, unique_for_month = :posted, blank = true)
    posted = DateField()
    Meta(table = "mf_post", verbose_name = "post")
end
@model struct MfDateTimePost
    title = CharField(max_length = 50, unique_for_date = :posted, blank = true)
    slug = CharField(max_length = 50, unique_for_year = :posted, blank = true)
    subtitle = CharField(max_length = 50, unique_for_month = :posted, blank = true)
    posted = DateTimeField(editable = false)
    Meta(table = "mf_datetimepost")
end
@model struct MfDerivedPost <: MfPost
    Meta(table = "mf_derivedpost", verbose_name = "derived post")
end
@model struct MfFlexibleDatePost
    title = CharField(max_length = 50, unique_for_date = :posted, blank = true)
    slug = CharField(max_length = 50, unique_for_year = :posted, blank = true)
    subtitle = CharField(max_length = 50, unique_for_month = :posted, blank = true)
    posted = DateField(blank = true, null = true)
    Meta(table = "mf_flexibledatepost")
end
redirect_stdout(devnull) do
    ms = [MfProduct, MfTriple, MfDerivedBook, MfExplicitPK, MfPost, MfDateTimePost, MfDerivedPost, MfFlexibleDatePost]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
mf_form(T) = (data = nothing; kw...) -> ModelForm(T; data, fields = "__all__", kw...)

@testset "django model_forms: UniqueTest" begin
  port_block() do
    writer = create(MfWriter; name = "Mike Royko")
    ProductForm, PriceForm, BookForm, DerivedBookForm, PostForm = mf_form(MfProduct), mf_form(MfPrice), mf_form(MfBook), mf_form(MfDerivedBook), mf_form(MfPost)
    # test_simple_unique
    form = ProductForm(Dict("slug" => "teddy-bear-blue"))
    @test is_valid(form)
    obj = save!(form)
    form = ProductForm(Dict("slug" => "teddy-bear-blue"))
    @test !is_valid(form) && form.errors == Dict(:slug => ["Product with this Slug already exists."])
    @test is_valid(ProductForm(Dict("slug" => "teddy-bear-blue"); instance = obj))
    # test_unique_together
    form = PriceForm(Dict("price" => "6.00", "quantity" => "1"))
    @test is_valid(form)
    save!(form)
    form = PriceForm(Dict("price" => "6.00", "quantity" => "1"))
    @test !is_valid(form) && form.errors == Dict(:__all__ => ["Price with this Price and Quantity already exists."])
    # test_unique_together_exclusion: only part of the unique_together is on the form, so it isn't checked
    create(MfDerivedBook; title = "x", isbn = "12345")
    form = ModelForm(MfDerivedBook; data = Dict("isbn" => "56789", "suffix1" => "0"), fields = (:isbn, :suffix1))
    @test is_valid(form)
    # test_multiple_field_unique_together
    create(MfTriple; left = 1, middle = 2, right = 3)
    @test !is_valid(mf_form(MfTriple)(Dict("left" => "1", "middle" => "2", "right" => "3")))
    @test is_valid(mf_form(MfTriple)(Dict("left" => "1", "middle" => "3", "right" => "1")))
    # test_unique_null
    title = "I May Be Wrong But I Doubt It"
    form = BookForm(Dict("title" => title, "author" => string(writer.id)))
    @test is_valid(form)
    save!(form)
    form = BookForm(Dict("title" => title, "author" => string(writer.id)))
    @test !is_valid(form) && form.errors == Dict(:__all__ => ["Book with this Title and Author already exists."])
    form = BookForm(Dict("title" => title))
    @test is_valid(form)
    save!(form)
    @test is_valid(BookForm(Dict("title" => title)))
    # test_inherited_unique
    create(MfBook; title = "Boss", author = writer, special_id = 1)
    form = DerivedBookForm(Dict("title" => "Other", "author" => string(writer.id), "special_id" => "1", "isbn" => "12345x"))
    @test !is_valid(form) && form.errors == Dict(:special_id => ["Book with this Special id already exists."])
    # test_inherited_unique_together
    form = BookForm(Dict("title" => "Boss2", "author" => string(writer.id)))
    @test is_valid(form)
    save!(form)
    form = DerivedBookForm(Dict("title" => "Boss2", "author" => string(writer.id), "isbn" => "12345y"))
    @test !is_valid(form) && form.errors == Dict(:__all__ => ["Book with this Title and Author already exists."])
    # test_abstract_inherited_unique, test_abstract_inherited_unique_together
    create(MfDerivedBook; title = "Boss3", author = writer, isbn = "777", suffix1 = 5, suffix2 = 5)
    form = DerivedBookForm(Dict("title" => "Other", "author" => string(writer.id), "isbn" => "777", "suffix1" => "1", "suffix2" => "2"))
    @test !is_valid(form) && form.errors == Dict(:isbn => ["Derived book with this Isbn already exists."])
    form = DerivedBookForm(Dict("title" => "Other", "author" => string(writer.id), "isbn" => "9876", "suffix1" => "5", "suffix2" => "5"))
    @test !is_valid(form) && form.errors == Dict(:__all__ => ["Derived book with this Suffix1 and Suffix2 already exists."])
    # test_explicitpk_unspecified, test_explicitpk_unique
    ExplicitPKForm(data) = ModelForm(MfExplicitPK; data, fields = (:key, :desc))
    @test !is_valid(ExplicitPKForm(Dict("key" => "", "desc" => "")))
    form = ExplicitPKForm(Dict("key" => "key1", "desc" => ""))
    @test is_valid(form)
    save!(form)
    form = ExplicitPKForm(Dict("key" => "key1", "desc" => ""))
    @test !is_valid(form) && form.errors == Dict(:__all__ => ["Explicit pk with this Key and Desc already exists."],
                                                 :desc => ["Explicit pk with this Desc already exists."], :key => ["Explicit pk with this Key already exists."])
  end
end

@testset "django model_forms: UniqueTest (unique_for_date, messages)" begin
  port_block() do
    for (PostT, label) in ((MfPost, "post"), (MfDerivedPost, "derived post"))       # test_unique_for_date, test_inherited_unique_for_date
        p = create(PostT; title = "Django 1.0 is released", slug = "Django 1.0", subtitle = "Finally", posted = Date(2008, 9, 3))
        PostForm = mf_form(PostT)
        form = PostForm(Dict("title" => "Django 1.0 is released", "posted" => "2008-09-03"))
        @test !is_valid(form) && form.errors == Dict(:title => ["Title must be unique for Posted date."])
        @test is_valid(PostForm(Dict("title" => "Work on Django 1.1 begins", "posted" => "2008-09-03")))
        @test is_valid(PostForm(Dict("title" => "Django 1.0 is released", "posted" => "2008-09-04")))
        form = PostForm(Dict("slug" => "Django 1.0", "posted" => "2008-01-01"))
        @test !is_valid(form) && form.errors == Dict(:slug => ["Slug must be unique for Posted year."])
        form = PostForm(Dict("subtitle" => "Finally", "posted" => "2008-09-30"))
        @test !is_valid(form) && form.errors[:subtitle] == ["Subtitle must be unique for Posted month."]
        data = Dict("subtitle" => "Finally", "title" => "Django 1.0 is released", "slug" => "Django 1.0", "posted" => "2008-09-03")
        @test is_valid(PostForm(data; instance = p))
        form = PostForm(Dict("title" => "Django 1.0 is released"))
        @test !is_valid(form) && form.errors == Dict(:posted => ["This field is required."])
        delete!(p)
    end
    # test_unique_for_date_in_exclude: the date isn't on the form (it isn't editable), so these aren't checked
    create(MfDateTimePost; title = "Django 1.0 is released", slug = "Django 1.0", subtitle = "Finally", posted = DateTime(2008, 9, 3, 10, 10, 1))
    DateTimePostForm = mf_form(MfDateTimePost)
    @test is_valid(DateTimePostForm(Dict("title" => "Django 1.0 is released", "posted" => "2008-09-03")))
    @test is_valid(DateTimePostForm(Dict("slug" => "Django 1.0", "posted" => "2008-01-01")))
    @test is_valid(DateTimePostForm(Dict("subtitle" => "Finally", "posted" => "2008-09-30")))
    # test_unique_for_date_with_nullable_date
    p = create(MfFlexibleDatePost; title = "Django 1.0 is released", slug = "Django 1.0", subtitle = "Finally", posted = Date(2008, 9, 3))
    FlexDatePostForm = mf_form(MfFlexibleDatePost)
    @test is_valid(FlexDatePostForm(Dict("title" => "Django 1.0 is released")))
    @test is_valid(FlexDatePostForm(Dict("slug" => "Django 1.0")))
    @test is_valid(FlexDatePostForm(Dict("subtitle" => "Finally")))
    @test is_valid(FlexDatePostForm(Dict("subtitle" => "Finally", "title" => "Django 1.0 is released", "slug" => "Django 1.0"); instance = p))
    # test_override_unique_message, test_override_unique_together_message, test_override_unique_for_date_message
    create(MfProduct; slug = "teddy-bear-blue")
    form = mf_form(MfProduct)(Dict("slug" => "teddy-bear-blue"); error_messages = Dict(:slug => Dict("unique" => "%(model_name)s's %(field_label)s not unique.")))
    @test !is_valid(form) && form.errors == Dict(:slug => ["Product's Slug not unique."])
    create(MfPrice; price = Decimal("6.00"), quantity = 1)
    form = mf_form(MfPrice)(Dict("price" => "6.00", "quantity" => "1");
                            error_messages = Dict(:__all__ => Dict("unique_together" => "%(model_name)s's %(field_labels)s not unique.")))
    @test !is_valid(form) && form.errors == Dict(:__all__ => ["Price's Price and Quantity not unique."])
    create(MfPost; title = "Django 1.0 is released", slug = "Django 1.0", subtitle = "Finally", posted = Date(2008, 9, 3))
    form = mf_form(MfPost)(Dict("title" => "Django 1.0 is released", "posted" => "2008-09-03");
                           error_messages = Dict(:title => Dict("unique_for_date" => "%(model_name)s's %(field_label)s not unique for %(date_field_label)s date.")))
    @test !is_valid(form) && form.errors == Dict(:title => ["Post's Title not unique for Posted date."])
  end
end

# Django's expected HTML for an ArticleForm, with Juango's differences: dates are `type="date"` inputs, and the
# empty choice is "---------" (Django 6.1's "- Select an option -" is #244)
function mf_article_ul(writers, cats; headline = "", slug = "", pub_date = "", writer = nothing, article = "", chosen = [], ids = false)
    v(x) = isempty(x) ? "" : " value=\"$x\""
    opt(val, label, sel) = "<option value=\"$val\"" * (sel ? " selected" : "") * ">" * Juango.escape_html(label) * "</option>"
    "<li>Headline: <input type=\"text\" name=\"headline\"$(v(headline)) maxlength=\"50\" required></li>" *
    "<li>Slug: <input type=\"text\" name=\"slug\"$(v(slug)) maxlength=\"50\" required></li>" *
    "<li>Pub date: <input type=\"date\" name=\"pub_date\"$(v(pub_date)) required></li>" *
    "<li>Writer: <select name=\"writer\" required>" * opt("", "---------", writer === nothing) *
        join(opt(w.id, w.name, writer !== nothing && w.id == writer.id) for w in writers) * "</select></li>" *
    "<li>Article: <textarea rows=\"10\" cols=\"40\" name=\"article\" required>$article</textarea></li>" *
    "<li>Categories: <select multiple name=\"categories\">" * join(opt(c.id, c.name, c.id in chosen) for c in cats) * "</select></li>" *
    "<li>Status: <select name=\"status\">" * opt("", "---------", true) * opt(1, "Draft", false) * opt(2, "Pending", false) * opt(3, "Live", false) * "</select></li>"
end
MfArticleForm(data = nothing; kw...) = ModelForm(MfArticle; data, fields = "__all__", kw...)
function mf_basic_data()
    c1 = create(MfCategory; name = "Entertainment", slug = "entertainment", url = "entertainment")
    c2 = create(MfCategory; name = "It's a test", slug = "its-test", url = "test")
    c3 = create(MfCategory; name = "Third test", slug = "third-test", url = "third")
    (c1, c2, c3), create(MfWriter; name = "Mike Royko"), create(MfWriter; name = "Bob Woodward")
end

@testset "django model_forms: ModelFormBasicTests (rendering, initial values)" begin
  port_block() do
    @test count(objects(MfCategory)) == 0                                                        # test_base_form
    f = MfCategoryForm()
    @test html_eq(as_div(f), "<div><label for=\"id_name\">Name:</label><input type=\"text\" name=\"name\" maxlength=\"20\" required id=\"id_name\"></div>" *
                             "<div><label for=\"id_slug\">Slug:</label><input type=\"text\" name=\"slug\" maxlength=\"20\" required id=\"id_slug\"></div>" *
                             "<div><label for=\"id_url\">The URL:</label><input type=\"text\" name=\"url\" maxlength=\"40\" required id=\"id_url\"></div>")
    @test html_eq(as_ul(f), "<li><label for=\"id_name\">Name:</label> <input id=\"id_name\" type=\"text\" name=\"name\" maxlength=\"20\" required></li>" *
                            "<li><label for=\"id_slug\">Slug:</label> <input id=\"id_slug\" type=\"text\" name=\"slug\" maxlength=\"20\" required></li>" *
                            "<li><label for=\"id_url\">The URL:</label> <input id=\"id_url\" type=\"text\" name=\"url\" maxlength=\"40\" required></li>")
    @test html_eq(w(f[:name]), "<input id=\"id_name\" type=\"text\" name=\"name\" maxlength=\"20\" required>")
    @test html_eq(as_ul(MfCategoryForm(; auto_id = false)),                                       # test_auto_id
                  "<li>Name: <input type=\"text\" name=\"name\" maxlength=\"20\" required></li>" *
                  "<li>Slug: <input type=\"text\" name=\"slug\" maxlength=\"20\" required></li>" *
                  "<li>The URL: <input type=\"text\" name=\"url\" maxlength=\"40\" required></li>")
    # test_initial_values
    (c1, c2, c3), royko, woodward = mf_basic_data()
    writers, cats = [woodward, royko], [c1, c2, c3]
    f = MfArticleForm(; auto_id = false, initial = Dict(:headline => "Your headline here", :categories => [string(c1.id), string(c2.id)]))
    @test html_eq(as_ul(f), mf_article_ul(writers, cats; headline = "Your headline here", chosen = [c1.id, c2.id]))
    f = ModelForm(MfWriter; fields = "__all__", auto_id = false, instance = royko)                # (an instance's values are the initial ones)
    @test html_eq(as_div(f), "<div>Name:<div class=\"helptext\">Use both first and last names.</div>" *
                             "<input type=\"text\" name=\"name\" value=\"Mike Royko\" maxlength=\"50\" required></div>")
    art = create(MfArticle; headline = "Test article", slug = "test-article", pub_date = Date(1988, 1, 4), writer = royko, article = "Hello.")
    @test html_eq(as_ul(MfArticleForm(; auto_id = false, instance = art)),
                  mf_article_ul(writers, cats; headline = "Test article", slug = "test-article", pub_date = "1988-01-04", writer = royko, article = "Hello."))
    f = MfArticleForm(Dict("headline" => "Test headline", "slug" => "test-headline", "pub_date" => "1984-02-06",
                           "writer" => string(royko.id), "article" => "Hello."); instance = art)
    @test is_valid(f) && isempty(f.errors)
    @test save!(f).id == art.id && get(MfArticle; id = art.id).headline == "Test headline"
    # test_m2m_initial_callable: a function as a many-to-many field's initial value
    callback = fld -> (fld.name === :categories && (fld.default = () -> collect(order_by(objects(MfCategory), "name"))[1:2]); fld)
    form = modelform_factory(MfArticle; fields = [:headline, :categories], formfield_callback = callback)()
    @test html_eq(as_ul(form), "<li><label for=\"id_headline\">Headline:</label> <input id=\"id_headline\" type=\"text\" name=\"headline\" maxlength=\"50\" required></li>" *
                               "<li><label for=\"id_categories\">Categories:</label> <select multiple name=\"categories\" id=\"id_categories\">" *
                               "<option value=\"$(c1.id)\" selected>Entertainment</option><option value=\"$(c2.id)\" selected>It&#x27;s a test</option>" *
                               "<option value=\"$(c3.id)\">Third test</option></select></li>")
    # test_multi_fields: many-to-many fields are a multiple select, foreign keys and fields with choices a select
    new_art = create(MfArticle; article = "Hello.", headline = "New headline", slug = "new-headline", pub_date = Date(1988, 1, 4), writer = royko)
    add!(new_art.categories, get(MfCategory; name = "Entertainment"))
    @test [c.id for c in new_art.categories] == [c1.id]
    @test html_eq(as_ul(MfArticleForm(; auto_id = false, instance = new_art)),
                  mf_article_ul(writers, cats; headline = "New headline", slug = "new-headline", pub_date = "1988-01-04", writer = royko,
                                article = "Hello.", chosen = [c1.id]))
    # test_runtime_choicefield_populated: the choices are read when the form is shown
    f = MfArticleForm(; auto_id = false)
    @test html_eq(as_ul(f), mf_article_ul(writers, cats))
    c4 = create(MfCategory; name = "Fourth", url = "4th")
    bernstein = create(MfWriter; name = "Carl Bernstein")
    @test html_eq(as_ul(f), mf_article_ul([woodward, bernstein, royko], [c1, c2, c3, c4]))
  end
end

@testset "django model_forms: ModelFormBasicTests (saving)" begin
  port_block() do
    # test_basic_creation
    f = MfCategoryForm(Dict("name" => "Entertainment", "slug" => "entertainment", "url" => "entertainment"))
    @test is_valid(f) && f.cleaned_data[:name] == "Entertainment" && f.cleaned_data[:slug] == "entertainment" && f.cleaned_data[:url] == "entertainment"
    c1 = save!(f)
    @test count(objects(MfCategory)) == 1 && first(objects(MfCategory)).id == c1.id && c1.name == "Entertainment"
    delete!(c1)
    # test_save_commit_false
    f = MfCategoryForm(Dict("name" => "Third test", "slug" => "third-test", "url" => "third"))
    @test is_valid(f)
    c1 = save!(f; commit = false)
    @test c1.name == "Third test" && count(objects(MfCategory)) == 0
    save!(c1)
    @test count(objects(MfCategory)) == 1
    # test_save_with_data_errors
    f = MfCategoryForm(Dict("name" => "", "slug" => "not a slug!", "url" => "foo"))
    @test !is_valid(f) && f.errors[:name] == ["This field is required."] &&
          f.errors[:slug] == ["Enter a valid “slug” consisting of letters, numbers, underscores or hyphens."] && f.cleaned_data == Dict(:url => "foo")
    msg = "The MfCategory could not be created because the data didn't validate."
    @test (try save!(f); "" catch e; e isa ArgumentError ? e.msg : rethrow() end) == msg
    @test (try save!(MfCategoryForm(Dict("name" => "", "slug" => "", "url" => "foo"))); "" catch e; e isa ArgumentError ? e.msg : rethrow() end) == msg
    @test (try save!(MfCategoryForm(Dict("name" => "", "slug" => "", "url" => "foo"); instance = c1)); "" catch e; e.msg end) ==
          "The MfCategory could not be changed because the data didn't validate."
    # test_subset_fields: a form of some of the fields
    @test html_eq(as_div(ModelForm(MfArticle; fields = (:headline, :pub_date), auto_id = false)),
                  "<div>Headline:<input type=\"text\" name=\"headline\" maxlength=\"50\" required></div><div>Pub date:<input type=\"date\" name=\"pub_date\" required></div>")
    royko = create(MfWriter; name = "Mike Royko")
    art = create(MfArticle; article = "Hello.", headline = "New headline", slug = "new-headline", pub_date = Date(1988, 1, 4), writer = royko)
    f = ModelForm(MfArticle; fields = (:headline, :slug, :pub_date), data = Dict("headline" => "New headline", "slug" => "new-headline", "pub_date" => "1988-01-04"),
                  auto_id = false, instance = art)
    @test html_eq(as_ul(f), "<li>Headline: <input type=\"text\" name=\"headline\" value=\"New headline\" maxlength=\"50\" required></li>" *
                            "<li>Slug: <input type=\"text\" name=\"slug\" value=\"new-headline\" maxlength=\"50\" required></li>" *
                            "<li>Pub date: <input type=\"date\" name=\"pub_date\" value=\"1988-01-04\" required></li>")
    @test is_valid(f) && save!(f).id == art.id && get(MfArticle; id = art.id).headline == "New headline"
    # test_m2m_editing
    cs = [create(MfCategory; name = n, slug = s, url = s) for (n, s) in (("Entertainment", "entertainment"), ("It's a test", "test"))]
    form_data = Dict{String,Any}("headline" => "New headline", "slug" => "new-headline", "pub_date" => "1988-01-04", "writer" => string(royko.id),
                                 "article" => "Hello.", "categories" => [string(c.id) for c in cs])
    new_art = get(MfArticle; id = save!(MfArticleForm(form_data)).id)
    art_id_1 = new_art.id
    @test [c.id for c in order_by(new_art.categories, "name")] == [c.id for c in cs]
    form_data["categories"] = String[]                                                       # (none: the article's are removed)
    new_art = save!(MfArticleForm(form_data; instance = new_art))
    @test new_art.id == art_id_1 && isempty(collect(get(MfArticle; id = art_id_1).categories))
    new_art = save!(MfArticleForm(form_data))
    art_id_2 = new_art.id
    @test !(art_id_2 in (nothing, art_id_1)) && isempty(collect(get(MfArticle; id = art_id_2).categories))
    form_data["categories"] = [string(c.id) for c in cs]                                     # commit = false: save_m2m! saves them
    f = MfArticleForm(form_data)
    new_art = save!(f; commit = false)
    save!(new_art)
    art_id_3 = new_art.id
    @test !(art_id_3 in (nothing, art_id_1, art_id_2)) && isempty(collect(get(MfArticle; id = art_id_3).categories))
    save_m2m!(f)
    @test [c.id for c in order_by(get(MfArticle; id = art_id_3).categories, "name")] == [c.id for c in cs]
    # test_custom_form_fields: declared fields standing in for all of the model's
    cat = create(MfCategory; name = "Third test")
    form = MfCategoryForm(Dict("name" => "Third", "slug" => "third", "url" => "3rd"); instance = cat,
                          extra_fields = [:name => CharField(max_length = 5), :slug => CharField(max_length = 5), :url => CharField(max_length = 3)])
    @test save!(form).name == "Third" && get(MfCategory; id = cat.id).name == "Third"
    # (test_callable_choices_are_lazy: Juango's choices are a vector)
    # test_validate_foreign_key_uses_default_manager: archived writers aren't in the default queryset
    w = create(MfWriter; name = "Randy", archived = true)
    data = Dict("headline" => "My Article", "slug" => "my-article", "pub_date" => string(Dates.today()), "writer" => string(w.id), "article" => "lorem ipsum")
    form = MfArticleForm(data)
    @test !is_valid(form) && form.errors == Dict(:writer => ["Select a valid choice. That choice is not one of the available choices."])
    # test_validate_foreign_key_to_model_with_overridden_manager: a choice of all the writers
    form = MfArticleForm(data; field_classes = Dict(:writer => ModelChoiceField(base_objects(MfWriter))))
    @test is_valid(form) && save!(form).writer.id == w.id
  end
end

mf_invalid(f, v) = clean_errors(f, v) !== nothing
mf_ids(xs) = sort([x.id for x in xs])
mf_choices(fld) = [(o.first, o.second) for o in Juango.choice_options(fld)]

@testset "django model_forms: ModelMultipleChoiceFieldTests" begin
  port_block() do
    c1 = create(MfCategory; name = "Entertainment", slug = "entertainment", url = "entertainment")
    c2 = create(MfCategory; name = "It's a test", slug = "its-test", url = "test")
    c3 = create(MfCategory; name = "Third", slug = "third-test", url = "third")
    # test_model_multiple_choice_field
    f = ModelMultipleChoiceField(objects(MfCategory))
    @test sort(mf_choices(f)) == sort([(string(c1.id), "Entertainment"), (string(c2.id), "It's a test"), (string(c3.id), "Third")])
    @test mf_invalid(f, nothing) && mf_invalid(f, [])
    @test mf_ids(Juango.clean(f, [c1.id])) == [c1.id] && mf_ids(Juango.clean(f, [c2.id])) == [c2.id] && mf_ids(Juango.clean(f, [string(c1.id)])) == [c1.id]
    @test mf_ids(Juango.clean(f, [string(c1.id), string(c2.id)])) == [c1.id, c2.id] && mf_ids(Juango.clean(f, [c1.id, string(c2.id)])) == [c1.id, c2.id]
    @test mf_ids(Juango.clean(f, (c1.id, string(c2.id)))) == [c1.id, c2.id]
    @test mf_invalid(f, ["0"]) && mf_invalid(f, "hello") && mf_invalid(f, ["fail"])
    @test mf_invalid(f, [["fail"]]) && mf_invalid(f, [Dict("foo" => "bar")])                     # (#22808)
    # the database is read when cleaning, not when the field is made
    c6 = create(MfCategory; name = "Sixth", url = "6th")
    @test mf_ids(Juango.clean(f, [c6.id])) == [c6.id]
    delete!(get(MfCategory; url = "6th"))
    @test mf_invalid(f, [c6.id])
    # test_model_multiple_choice_required_false
    f = ModelMultipleChoiceField(objects(MfCategory); required = false)
    @test isempty(Juango.clean(f, [])) && isempty(Juango.clean(f, ()))
    @test mf_invalid(f, ["0"]) && mf_invalid(f, [string(c3.id), "0"]) && mf_invalid(f, [string(c1.id), "0"])
    f = ModelMultipleChoiceField(exclude(objects(MfCategory); name = "Third"); required = false)       # (another queryset)
    @test sort(mf_choices(f)) == sort([(string(c1.id), "Entertainment"), (string(c2.id), "It's a test")])
    @test mf_ids(Juango.clean(f, [c2.id])) == [c2.id] && mf_invalid(f, [c3.id]) && mf_invalid(f, [string(c2.id), string(c3.id)])
    f = ModelMultipleChoiceField(objects(MfCategory); required = false, label_from_instance = o -> "multicategory " * o.name)
    @test sort(mf_choices(f)) == sort([(string(c1.id), "multicategory Entertainment"), (string(c2.id), "multicategory It's a test"),
                                       (string(c3.id), "multicategory Third")])
    # test_model_multiple_choice_number_of_queries: one query (#10156)
    persons = [create(MfWriter; name = "Person $i") for i in 0:29]
    f = ModelMultipleChoiceField(objects(MfWriter))
    @test assert_num_queries(() -> Juango.clean(f, [p.id for p in persons[2:2:11]]), 1)
    # test_model_multiple_choice_null_characters
    f = ModelMultipleChoiceField(objects(MfExplicitPK))
    @test raises(f, ["\0something"], "Null characters are not allowed.") && raises(f, ["valid", "\0something"], "Null characters are not allowed.")
    # test_model_multiple_choice_run_validators (#14144)
    ran = Ref(false)
    f = ModelMultipleChoiceField(objects(MfWriter); validators = [v -> (ran[] = true; nothing)])
    Juango.clean(f, [persons[9].id])
    @test ran[]
    # test_model_multiple_choice_show_hidden_initial
    person1, person2 = create(MfWriter; name = "Person 1"), create(MfWriter; name = "Person 2")
    writer_form(data) = Form([:persons => ModelMultipleChoiceField(objects(MfWriter); show_hidden_initial = true)];
                             initial = Dict(:persons => [person1, person2]), data)
    form = writer_form(Dict("initial-persons" => [string(person1.id), string(person2.id)], "persons" => [string(person1.id), string(person2.id)]))
    @test is_valid(form) && !has_changed(form)
    form = writer_form(Dict("initial-persons" => [string(person1.id), string(person2.id)], "persons" => [string(person2.id)]))
    @test is_valid(form) && has_changed(form)
    # (test_model_multiple_choice_field_22745, test_show_hidden_initial_changed_queries_efficiently and
    # test_clean_does_deduplicate_values count queries and SQL parameters of Django's own implementation)
    # test_to_field_name_with_initial_data
    article = create(MfArticle; headline = "Test article", slug = "test-article", pub_date = Date(1988, 1, 4),
                     writer = create(MfWriter; name = "Test writer"), article = "Hello.")
    add!(article.categories, c2, c3)
    form = ModelForm(MfArticle; fields = [:categories], instance = article,
                     extra_fields = [:categories => ModelMultipleChoiceField(objects(MfCategory); to_field_name = :slug)])
    @test Juango.chosen_values(form[:categories]) == Set([c2.slug, c3.slug])
  end
end

@model struct MfImprovedArticle
    article = OneToOneField(MfArticle, on_delete = :CASCADE)
    Meta(table = "mf_improvedarticle")
end
@model struct MfBetterWriter <: MfWriter
    score = IntegerField()
    Meta(table = "mf_betterwriter")
end
@model struct MfWriterProfile
    writer = OneToOneField(MfWriter, on_delete = :CASCADE)
    age = PositiveIntegerField()
    Meta(table = "mf_writerprofile")
end
Base.show(io::IO, p::MfWriterProfile) = print(io, p.writer, " is ", p.age)
@model struct MfPublication
    title = CharField(max_length = 30)
    date_published = DateField()
    Meta(table = "mf_publication")
end
@model struct MfAuthor
    publication = OneToOneField(MfPublication, on_delete = :SET_NULL, null = true, blank = true)
    full_name = CharField(max_length = 255)
    Meta(table = "mf_author")
end
@model struct MfAuthor1
    publication = OneToOneField(MfPublication, on_delete = :CASCADE, null = false)
    full_name = CharField(max_length = 255)
    Meta(table = "mf_author1")
end
redirect_stdout(devnull) do
    ms = [MfImprovedArticle, MfBetterWriter, MfWriterProfile, MfPublication, MfAuthor, MfAuthor1]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_forms: ModelOneToOneFieldTests, ModelToDictTests" begin
  port_block() do
    # test_modelform_onetoonefield (ImprovedArticleWithParentLink: Juango has no parent_link)
    @test mf_names(ModelForm(MfImprovedArticle; fields = "__all__")) == [:article]
    # test_modelform_subclassed_model (a multi-table child: Juango has no writer_ptr field)
    bw = create(MfBetterWriter; name = "Joe Better", score = 10)
    @test sort(collect(keys(model_to_dict(bw)))) == [:id, :name, :score]
    @test isempty(model_to_dict(bw; fields = []))
    @test sort(collect(keys(model_to_dict(bw; fields = [:id, :name])))) == [:id, :name]
    @test sort(collect(keys(model_to_dict(bw; exclude = [])))) == [:id, :name, :score]
    @test sort(collect(keys(model_to_dict(bw; exclude = [:id, :name])))) == [:score]
    form = ModelForm(MfBetterWriter; data = Dict("name" => "Some Name", "score" => "12"), fields = "__all__")
    @test is_valid(form) && save!(form).score == 12
    # test_onetoonefield
    royko, woodward = create(MfWriter; name = "Mike Royko"), create(MfWriter; name = "Bob Woodward")
    profile_form(data = nothing; kw...) = ModelForm(MfWriterProfile; data, fields = "__all__", kw...)
    # (the writers made above are there too)
    profile_p(sel, age) = "<p><label for=\"id_writer\">Writer:</label> <select name=\"writer\" id=\"id_writer\" required>" *
        "<option value=\"\"$(sel === nothing ? " selected" : "")>---------</option>" *
        join("<option value=\"$(x.id)\"$(sel !== nothing && x.id == sel.id ? " selected" : "")>$(x.name)</option>" for x in objects(MfWriter)) * "</select></p>" *
        "<p><label for=\"id_age\">Age:</label> <input type=\"number\" name=\"age\"$(age === nothing ? "" : " value=\"$age\"") id=\"id_age\" min=\"0\" required></p>"
    @test html_eq(as_p(profile_form()), profile_p(nothing, nothing))
    instance = save!(profile_form(Dict("writer" => string(woodward.id), "age" => "65")))
    @test string(instance) == "Bob Woodward is 65"
    @test html_eq(as_p(profile_form(; instance)), profile_p(woodward, 65))
    # test_assignment_of_none
    publication = create(MfPublication; title = "Pravda", date_published = Date(1991, 8, 22))
    author = create(MfAuthor; publication, full_name = "John Doe")
    form = ModelForm(MfAuthor; data = Dict("publication" => "", "full_name" => "John Doe"), instance = author, fields = [:publication, :full_name])
    @test is_valid(form) && form.cleaned_data[:publication] === nothing
    author = save!(form)
    @test get(MfAuthor; id = author.id).publication === nothing
    # test_assignment_of_none_null_false
    author = create(MfAuthor1; publication, full_name = "John Doe")
    @test !is_valid(ModelForm(MfAuthor1; data = Dict("publication" => "", "full_name" => "John Doe"), instance = author, fields = [:publication, :full_name]))
  end
end

const MF_STORAGE = Juango.InMemoryStorage()
@model struct MfDocument
    myfile = FileField(storage = MF_STORAGE, upload_to = "unused", blank = true)
    Meta(table = "mf_document")
end
@model struct MfTextFile
    description = CharField(max_length = 20)
    file = FileField(storage = MF_STORAGE, upload_to = "tests", max_length = 15)
    Meta(table = "mf_textfile")
end
redirect_stdout(devnull) do
    ms = [MfDocument, MfTextFile]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_forms: FileAndImageFieldTests" begin
  port_block() do
    # test_clean_false: false (clear the file) cleans to false, whatever the initial value
    f = FileField(required = false)
    @test Juango.clean(f, false) === false && Juango.clean(f, false, "initial") === false
    # test_clean_false_required: false is as nothing, so the initial value is kept or the field is required
    f = FileField(required = true)
    @test Juango.clean(f, false, "initial") == "initial" && clean_errors(f, false) !== nothing
    # test_full_clear: set and cleared through a ModelForm
    doc_form(; kw...) = ModelForm(MfDocument; fields = "__all__", kw...)
    @test occursin("name=\"myfile\"", as_p(doc_form()).s) && !occursin("myfile-clear", as_p(doc_form()).s)
    form = doc_form(; data = Dict{String,Any}(), files = Dict{String,Any}("myfile" => UploadedFile("something.txt", "content")))
    @test is_valid(form)
    doc = save!(form; commit = false)
    @test doc.myfile.name == "something.txt"
    @test occursin("myfile-clear", as_p(doc_form(; instance = doc)).s)
    doc = save!(doc_form(; instance = doc, data = Dict{String,Any}("myfile-clear" => "true")); commit = false)
    @test !Juango.truthy(doc.myfile)
    # test_clear_and_file_contradiction: the bound form still shows the current file and the clear checkbox
    doc = save!(doc_form(; data = Dict{String,Any}(), files = Dict{String,Any}("myfile" => UploadedFile("something.txt", "content"))))
    form = doc_form(; instance = doc, files = Dict{String,Any}("myfile" => UploadedFile("something.txt", "content")), data = Dict{String,Any}("myfile-clear" => "true"))
    @test !is_valid(form) && form.errors[:myfile] == ["Please either submit a file or check the clear checkbox, not both."]
    rendered = as_p(form).s
    @test occursin("something.txt", rendered) && occursin("myfile-clear", rendered)
    # test_render_empty_file_field
    @test html_eq(w(doc_form(; instance = create(MfDocument))[:myfile]), "<input id=\"id_myfile\" name=\"myfile\" type=\"file\">")
    # test_file_field_data
    text_form(data; kw...) = ModelForm(MfTextFile; data, fields = "__all__", kw...)
    @test !is_valid(text_form(Dict("description" => "Assistance")))
    @test !is_valid(text_form(Dict("description" => "Assistance"); files = Dict{String,Any}()))
    f = text_form(Dict("description" => "Assistance"); files = Dict{String,Any}("file" => UploadedFile("test1.txt", "hello world")))
    @test is_valid(f) && f.cleaned_data[:file] isa UploadedFile
    instance = save!(f)
    @test instance.file.name == "tests/test1.txt"
    Juango.delete_file(MF_STORAGE, instance.file.name)
    f = text_form(Dict("description" => "Assistance"); files = Dict{String,Any}("file" => UploadedFile("test1.txt", "hello world")))
    @test is_valid(f)
    @test save!(f).file.name == "tests/test1.txt"          # (a deleted file's name can be used again)
    instance = get(MfTextFile; id = f.instance.id)
    # the model's max_length is the form field's
    @test !is_valid(text_form(Dict("description" => "Assistance"); files = Dict{String,Any}("file" => UploadedFile("test-maxlength.txt", "hello world"))))
    # editing an instance with a file leaves the file as it is
    f = text_form(Dict("description" => "Assistance"); instance)
    @test is_valid(f)
    @test f.cleaned_data[:file] isa Juango.FieldFile && f.cleaned_data[:file].name == "tests/test1.txt"
    @test save!(f).file.name == "tests/test1.txt"
    Juango.delete_file(MF_STORAGE, instance.file.name)
    f = text_form(Dict("description" => "Assistance"); files = Dict{String,Any}("file" => UploadedFile("test2.txt", "hello world")), instance)
    @test is_valid(f) && save!(f).file.name == "tests/test2.txt"
    # test_filefield_required_false (Juango's empty file field is nothing, Django's "")
    optional_file = not_required(:file)
    f = text_form(Dict("description" => "Assistance"); formfield_callback = optional_file)
    @test is_valid(f)
    instance = save!(f)
    @test instance.file === nothing
    f = text_form(Dict("description" => "Assistance"); files = Dict{String,Any}("file" => UploadedFile("test3.txt", "hello world")), instance)
    @test is_valid(f) && (instance = save!(f)).file.name == "tests/test3.txt"
    f = text_form(Dict("description" => "New Description"); instance, formfield_callback = optional_file)
    @test is_valid(f)
    instance = save!(f)
    @test instance.description == "New Description" && instance.file.name == "tests/test3.txt"
    # (test_custom_file_field_save, test_file_field_multiple_save: Django's save_form_data and save counts;
    # test_file_path_field_blank and test_image_field: FilePathField and ImageField are ported in field_tests)
  end
end

@model struct MfBigInt
    biggie = BigIntegerField()
    Meta(table = "mf_bigint")
end
@model struct MfHomepage
    url = URLField()
    Meta(table = "mf_homepage")
end
@model struct MfArticleStatus
    status = CharField(max_length = 2, choices = [("d", "Draft"), ("p", "Pending"), ("l", "Live")], blank = true, null = true)
    Meta(table = "mf_articlestatus")
end
@model struct MfInventory
    barcode = PositiveIntegerField(unique = true)
    parent = ForeignKey(:MfInventory, on_delete = :SET_NULL, to_field = :barcode, blank = true, null = true)
    name = CharField(blank = false, max_length = 20)
    Meta(table = "mf_inventory", ordering = ["name"])
end
Base.show(io::IO, i::MfInventory) = print(io, i.name)
@model struct MfColor
    name = CharField(max_length = 50)
    Meta(table = "mf_color", ordering = ["name"])
end
Base.show(io::IO, c::MfColor) = print(io, c.name)
@model struct MfColorfulItem
    name = CharField(max_length = 50)
    colors = ManyToManyField(MfColor)
    Meta(table = "mf_colorfulitem", ordering = ["pk"])
end
redirect_stdout(devnull) do
    ms = [MfBigInt, MfHomepage, MfArticleStatus, MfInventory, MfColor, MfColorfulItem, through(MfColorfulItem, :colors)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_forms: ModelOtherFieldTests, OtherModelFormTests" begin
  port_block() do
    # test_big_integer_field
    bif(v) = ModelForm(MfBigInt; data = Dict("biggie" => v), fields = "__all__")
    @test is_valid(bif("-9223372036854775808")) && is_valid(bif("9223372036854775807"))
    f = bif("-9223372036854775809")
    @test !is_valid(f) && f.errors == Dict(:biggie => ["Ensure this value is greater than or equal to -9223372036854775808."])
    f = bif("9223372036854775808")
    @test !is_valid(f) && f.errors == Dict(:biggie => ["Ensure this value is less than or equal to 9223372036854775807."])
    # test_url_on_modelform
    homepage(v) = ModelForm(MfHomepage; data = Dict("url" => v), fields = "__all__")
    for u in ("foo", "http://", "http://example", "http://example.", "http://com.")
        @test (u, is_valid(homepage(u))) == (u, false)
    end
    for u in ("http://localhost", "http://example.com", "http://www.example.com", "http://www.example.com:8000", "http://www.example.com/test",
              "http://www.example.com:8000/test", "http://example.com/foo/bar")
        @test (u, is_valid(homepage(u))) == (u, true)
    end
    # test_modelform_non_editable_field
    @test !(:created in mf_names(MfArticleForm()))
    @test unknown_fields(() -> ModelForm(MfArticle; fields = (:headline, :created))) ==
          "'created' cannot be specified for MfArticle model form as it is a non-editable field"
    # test_https_prefixing
    form = homepage("example.com")
    @test is_valid(form) && form.cleaned_data[:url] == "https://example.com"
    form = homepage("example.com/test")
    @test is_valid(form) && form.cleaned_data[:url] == "https://example.com/test"
    # test_media_on_modelform
    f = ModelForm(MfHomepage; fields = "__all__", media = Media(css = Dict("all" => ["/some/form/css"]), js = ["/some/form/javascript"]))
    @test html_eq(string(Juango.render_media(f.media)), "<link href=\"/some/form/css\" media=\"all\" rel=\"stylesheet\"><script src=\"/some/form/javascript\"></script>")
    # test_choices_type
    @test clean_errors(MfArticleForm()[:status].field, "42") !== nothing
    @test clean_errors(ModelForm(MfArticleStatus; fields = "__all__")[:status].field, "z") !== nothing
    # (test_prefetch_related_queryset counts Django's queries)
    # test_foreignkeys_which_use_to_field
    apple = create(MfInventory; barcode = 86, name = "Apple")
    pear = create(MfInventory; barcode = 22, name = "Pear")
    core = create(MfInventory; barcode = 87, name = "Core", parent = apple)
    field = ModelChoiceField(objects(MfInventory); to_field_name = :barcode)
    @test mf_choices(field) == [("86", "Apple"), ("87", "Core"), ("22", "Pear")]
    inventory_form(; kw...) = ModelForm(MfInventory; fields = "__all__", kw...)
    @test html_eq(w(inventory_form(; instance = core)[:parent]),
                  "<select name=\"parent\" id=\"id_parent\"><option value=\"\">---------</option><option value=\"86\" selected>Apple</option>" *
                  "<option value=\"87\">Core</option><option value=\"22\">Pear</option></select>")
    data = Dict{String,Any}(string(k) => (v === nothing ? "" : string(v)) for (k, v) in model_to_dict(core))
    data["parent"] = "22"
    core = save!(inventory_form(; data, instance = core))
    @test core.parent.name == "Pear"
    form = ModelForm(MfCategory; fields = [:description, :url], extra_fields = [:description => CharField(max_length = nothing)])
    @test mf_names(form) == [:description, :url]
    @test html_eq(as_div(form), "<div><label for=\"id_description\">Description:</label><input type=\"text\" name=\"description\" required id=\"id_description\"></div>" *
                                "<div><label for=\"id_url\">The URL:</label><input type=\"text\" name=\"url\" maxlength=\"40\" required id=\"id_url\"></div>")
    field = ModelMultipleChoiceField(objects(MfInventory); to_field_name = :barcode)
    @test mf_choices(field) == [("86", "Apple"), ("87", "Core"), ("22", "Pear")]
    @test [x.id for x in Juango.clean(field, [86])] == [apple.id]
    form = Form([:items => ModelMultipleChoiceField(objects(MfInventory); to_field_name = :barcode)]; data = Dict("items" => ["87", "22"]))
    @test is_valid(form) && length(form.cleaned_data) == 1 && sort([x.id for x in form.cleaned_data[:items]]) == sort([core.id, pear.id])
    # (test_model_field_that_returns_none_to_exclude_itself_with_explicit_fields: formfield_callback returning nothing, in ModelFormBaseTest)
    # test_iterable_model_m2m
    color = create(MfColor; name = "Blue")
    @test html_eq(as_p(ModelForm(MfColorfulItem; fields = "__all__")),
                  "<p><label for=\"id_name\">Name:</label> <input id=\"id_name\" type=\"text\" name=\"name\" maxlength=\"50\" required></p>" *
                  "<p><label for=\"id_colors\">Colors:</label> <select multiple name=\"colors\" id=\"id_colors\" required>" *
                  "<option value=\"$(color.id)\">Blue</option></select></p>")
    # test_callable_field_default: a field whose default is a function has its initial value in a hidden input too
    pub_defaults(data = nothing) = ModelForm(MfPublicationDefaults; data, fields = (:title, :date_published, :mode, :category))
    today_str = string(Dates.today())
    @test html_eq(as_p(pub_defaults()),
                  "<p><label for=\"id_title\">Title:</label> <input id=\"id_title\" maxlength=\"30\" name=\"title\" type=\"text\" required></p>" *
                  "<p><label for=\"id_date_published\">Date published:</label> <input id=\"id_date_published\" name=\"date_published\" type=\"date\" value=\"$today_str\" required>" *
                  "<input id=\"initial-id_date_published\" name=\"initial-date_published\" type=\"hidden\" value=\"$today_str\"></p>" *
                  "<p><label for=\"id_mode\">Mode:</label> <select id=\"id_mode\" name=\"mode\"><option value=\"di\" selected>direct</option>" *
                  "<option value=\"de\">delayed</option></select><input id=\"initial-id_mode\" name=\"initial-mode\" type=\"hidden\" value=\"di\"></p>" *
                  "<p><label for=\"id_category\">Category:</label> <select id=\"id_category\" name=\"category\"><option value=\"1\">Games</option>" *
                  "<option value=\"2\">Comics</option><option value=\"3\" selected>Novel</option></select>" *
                  "<input id=\"initial-id_category\" name=\"initial-category\" type=\"hidden\" value=\"3\"></p>")
    @test !has_changed(pub_defaults(Dict("title" => "", "date_published" => today_str, "initial-date_published" => today_str, "mode" => "di",
                                         "initial-mode" => "di", "category" => "3", "initial-category" => "3")))
  end
end

@model struct MfCustomErrorMessage
    name1 = CharField(max_length = 50, validators = [validate_slug], error_messages = Dict("invalid" => "Model custom error message."))
    name2 = CharField(max_length = 50, validators = [validate_slug], error_messages = Dict("invalid" => "Model custom error message."))
    Meta(table = "mf_customerrormessage")
end
function Juango.clean(o::MfCustomErrorMessage)
    o.name1 == "FORBIDDEN_VALUE" && throw(Juango.ValidationError(Dict(:name1 => [Juango.ValidationError("Model.clean() error messages.")])))
    o.name1 == "FORBIDDEN_VALUE2" && throw(Juango.ValidationError(Dict(:name1 => "Model.clean() error messages (simpler syntax).")))
    o.name1 == "GLOBAL_ERROR" && throw(Juango.ValidationError("Global error message."))
    nothing
end
@model struct MfStumpJoke
    most_recently_fooled = ForeignKey(MfCharacter, on_delete = :CASCADE, related_name = :jokes,
                                      limit_choices_to = () -> Dict(:last_action__gte => Dates.today()))
    has_fooled_today = ManyToManyField(MfCharacter; related_name = :jokes_today, limit_choices_to = () -> Q(last_action__gte = Dates.today()))
    funny = BooleanField(default = false)
    Meta(table = "mf_stumpjoke")
end
@model struct MfCharacterDetails
    character1 = ForeignKey(MfCharacter, on_delete = :CASCADE, related_name = :details_fk_1,
                            limit_choices_to = Q(jokes__funny = true, jokes_today__funny = true))
    character2 = ForeignKey(MfCharacter, on_delete = :CASCADE, related_name = :details_fk_2,
                            limit_choices_to = Dict(:jokes__funny => true, :jokes_today__funny => true))
    character3 = ManyToManyField(MfCharacter; related_name = :details_m2m_1, limit_choices_to = Q(jokes__funny = true, jokes_today__funny = true))
    Meta(table = "mf_characterdetails")
end
@model struct MfConstraintsModel
    name = CharField(max_length = 100)
    category = CharField(max_length = 50, default = "uncategorized")
    price = DecimalField(max_digits = 10, decimal_places = 2, default = 0)
    Meta(table = "mf_constraintsmodel",
         constraints = [UniqueConstraint(fields = [:name, :category], name = "mf_unique_name_category", violation_error_message = "This product already exists."),
                        CheckConstraint(condition = Q(price__gt = 0), name = "mf_price_gte_zero", violation_error_message = "Price must be greater than zero.")])
end
redirect_stdout(devnull) do
    ms = [MfCustomErrorMessage, MfStumpJoke, through(MfStumpJoke, :has_fooled_today), MfCharacterDetails, through(MfCharacterDetails, :character3),
          MfConstraintsModel]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_forms: custom errors, custom clean, limit_choices_to" begin
  port_block() do
    # ModelFormCustomErrorTests: the form field's messages, then the model field's
    cem_form(data) = ModelForm(MfCustomErrorMessage; data, fields = "__all__",
                               extra_fields = [:name1 => CharField(error_messages = Dict("invalid" => "Form custom error message."), validators = [validate_slug])])
    t(src, f) = render(Template(src), Dict{String,Any}("form" => f))
    form = cem_form(Dict("name1" => "@#\$!!**@#\$", "name2" => "@#\$!!**@#\$"))
    @test !is_valid(form)
    @test html_eq(t("{{ form.name1.errors }}", form), "<ul class=\"errorlist\" id=\"id_name1_error\"><li>Form custom error message.</li></ul>")
    @test html_eq(t("{{ form.name2.errors }}", form), "<ul class=\"errorlist\" id=\"id_name2_error\"><li>Model custom error message.</li></ul>")
    # test_model_clean_error_messages
    form = cem_form(Dict("name1" => "FORBIDDEN_VALUE", "name2" => "ABC"))
    @test !is_valid(form) && form.errors[:name1] == ["Model.clean() error messages."]
    form = cem_form(Dict("name1" => "FORBIDDEN_VALUE2", "name2" => "ABC"))
    @test !is_valid(form) && form.errors[:name1] == ["Model.clean() error messages (simpler syntax)."]
    form = cem_form(Dict("name1" => "GLOBAL_ERROR", "name2" => "ABC"))
    @test !is_valid(form) && form.errors[:__all__] == ["Global error message."]
    # CustomCleanTests: test_override_clean (Juango's instance is made by save!)
    clean_lr(f) = f.cleaned_data[:left] == f.cleaned_data[:right] || throw(Juango.ValidationError("Left and right should be equal"))
    form = ModelForm(MfTriple; data = Dict("left" => "1", "middle" => "2", "right" => "1"), fields = "__all__", clean = clean_lr)
    @test is_valid(form) && save!(form; commit = false).left == 1
    # test_model_form_clean_applies_to_model
    form = MfCategoryForm(Dict("name" => "Test", "slug" => "test", "url" => "/test"); clean = f -> (f.cleaned_data[:name] = uppercase(f.cleaned_data[:name]); f.cleaned_data))
    @test save!(form).name == "TEST"
    # (ModelFormInheritanceTests: Python class inheritance of forms)

    # LimitChoicesToTests
    threepwood = create(MfCharacter; username = "threepwood", last_action = now() + Day(1))
    marley = create(MfCharacter; username = "marley", last_action = now() - Day(1))
    fk_ids(form, name) = sort([parse(Int, o.first) for o in Juango.choice_options(form[name].field)])
    stump = ModelForm(MfStumpJoke; fields = "__all__")
    @test fk_ids(stump, :most_recently_fooled) == [threepwood.id]                  # test_limit_choices_to_callable_for_fk_rel
    @test fk_ids(stump, :has_fooled_today) == [threepwood.id]                      # test_limit_choices_to_callable_for_m2m_rel
    @test [o.first for o in Juango.choice_options(Dict(fields_for_model(MfStumpJoke; fields = [:has_fooled_today]))[:has_fooled_today])] ==
          [string(threepwood.id)]                                                    # test_fields_for_model_applies_limit_choices_to
    # a choice the limit leaves out isn't valid
    form = ModelForm(MfStumpJoke; fields = [:most_recently_fooled], data = Dict("most_recently_fooled" => string(marley.id)))
    @test !is_valid(form) && form.errors[:most_recently_fooled] == ["Select a valid choice. That choice is not one of the available choices."]
    # test_limit_choices_to_no_duplicates
    joke1 = create(MfStumpJoke; funny = true, most_recently_fooled = threepwood)
    joke2 = create(MfStumpJoke; funny = true, most_recently_fooled = threepwood)
    joke3 = create(MfStumpJoke; funny = true, most_recently_fooled = marley)
    create(MfStumpJoke; funny = false, most_recently_fooled = marley)
    add!(joke1.has_fooled_today, marley, threepwood)
    add!(joke2.has_fooled_today, marley)
    add!(joke3.has_fooled_today, marley, threepwood)
    details = ModelForm(MfCharacterDetails; fields = "__all__")
    for name in (:character1, :character2, :character3)
        @test (name, fk_ids(details, name)) == (name, sort([marley.id, threepwood.id]))
    end
    # (test_custom_field_with_queryset_but_no_limit_choices_to, test_callable_called_each_time_form_is_instantiated: Django's internals;
    # test_limit_choices_to_m2m_through: through models aren't editable in Juango's forms)
  end
end

@testset "django model_forms: FormFieldCallbackTests, LocalizedModelFormTest, ConstraintValidationTests" begin
  port_block() do
    # test_factory_with_widget_argument (#15315)
    @test Juango.widget_kind(modelform_factory(MfPerson; fields = "__all__")()[:name].field.widget) !== :textarea
    @test modelform_factory(MfPerson; fields = "__all__", widgets = Dict(:name => :textarea))()[:name].field.widget === :textarea
    @test mf_names(modelform_factory(MfPerson; fields = "__all__")()) == [:name]               # test_modelform_factory_with_all_fields
    # (test_modelform_factory_without_fields: Juango takes all the editable fields)
    # test_custom_callback: called with each field, after Meta's widgets
    seen = []
    modelform_factory(MfPerson; fields = "__all__", widgets = Dict(:name => :textarea), formfield_callback = f -> (push!(seen, (f.name, f.widget)); f))
    @test seen[end] == (:name, :textarea)
    # test_bad_callback
    @test_throws MethodError modelform_factory(MfPerson; fields = "__all__", formfield_callback = "not a function or callable")
    # test_custom_callback_in_meta
    form = modelform_factory(MfPerson; fields = [:name], formfield_callback = f -> CharField(widget = :textarea))()
    @test all(x -> x.widget === :textarea, form.fields)
    # LocalizedModelFormTest
    f = ModelForm(MfTriple; data = Dict("left" => "10", "middle" => "10", "right" => "10"), fields = "__all__", localized_fields = (:left, :right))
    @test is_valid(f) && Juango.is_localized(f[:left].field) && !Juango.is_localized(f[:middle].field) && Juango.is_localized(f[:right].field)
    f = ModelForm(MfTriple; data = Dict("left" => "10", "middle" => "10", "right" => "10"), fields = "__all__", localized_fields = "__all__")
    @test is_valid(f) && all(x -> Juango.is_localized(x), f.fields)
    @test (try ModelForm(MfTriple; fields = "__all__", localized_fields = "foo"); false catch e; e isa ArgumentError && occursin("cannot be a string", e.msg) end)
    # (StrictAssignmentTests: Juango's models have no __setattr__ to raise)
    # ConstraintValidationTests: a constraint on a field the form leaves out isn't checked
    obj = create(MfConstraintsModel; name = "product", price = Decimal("1.00"))
    data = Dict("id" => "", "name" => obj.name, "price" => "1337.00", "category" => obj.category)
    @test is_valid(modelform_factory(MfConstraintsModel; exclude = [:category])(data))
    full_form = modelform_factory(MfConstraintsModel; fields = "__all__")(data)
    @test !is_valid(full_form) && full_form.errors == Dict(:__all__ => ["This product already exists."])
    data = Dict("id" => "", "name" => "priceless", "price" => "0.00", "category" => "category 1")
    @test is_valid(modelform_factory(MfConstraintsModel; exclude = [:price])(data))
    full_form = modelform_factory(MfConstraintsModel; fields = "__all__")(data)
    @test !is_valid(full_form) && full_form.errors == Dict(:__all__ => ["Price must be greater than zero."])
  end
end

# --- tests/model_formsets/models.py ---------------------------------------------------------------------
@model struct MfsAuthor
    name = CharField(max_length = 100)
    Meta(table = "mfs_author", ordering = ["name"])
end
Base.show(io::IO, a::MfsAuthor) = print(io, a.name)
@model struct MfsBetterAuthor <: MfsAuthor
    write_speed = IntegerField()
    Meta(table = "mfs_betterauthor")
end
@model struct MfsBook
    author = ForeignKey(MfsAuthor, on_delete = :CASCADE)
    title = CharField(max_length = 100)
    Meta(table = "mfs_book", unique_together = [(:author, :title)], ordering = ["id"])
end
Base.show(io::IO, b::MfsBook) = print(io, b.title)
@model struct MfsCustomPrimaryKey
    my_pk = CharField(max_length = 10, primary_key = true)
    some_field = CharField(max_length = 100)
    Meta(table = "mfs_customprimarykey")
end
@model struct MfsPlace
    name = CharField(max_length = 50)
    city = CharField(max_length = 50)
    Meta(table = "mfs_place")
end
Base.show(io::IO, p::MfsPlace) = print(io, p.name)
@model struct MfsOwner
    name = CharField(max_length = 100)
    place = ForeignKey(MfsPlace, on_delete = :CASCADE)
    Meta(table = "mfs_owner", ordering = ["id"])
end
Base.show(io::IO, o::MfsOwner) = print(io, o.name, " at ", o.place)
@model struct MfsOwnerProfile
    owner = OneToOneField(MfsOwner, on_delete = :CASCADE)
    age = PositiveIntegerField()
    Meta(table = "mfs_ownerprofile")
end
@model struct MfsPoet
    name = CharField(max_length = 100)
    Meta(table = "mfs_poet")
end
Base.show(io::IO, p::MfsPoet) = print(io, p.name)
@model struct MfsPoem
    poet = ForeignKey(MfsPoet, on_delete = :CASCADE)
    name = CharField(max_length = 100)
    Meta(table = "mfs_poem")
end
redirect_stdout(devnull) do
    ms = [MfsAuthor, MfsBetterAuthor, MfsBook, MfsCustomPrimaryKey, MfsPlace, MfsOwner, MfsOwnerProfile, MfsPoet, MfsPoem]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_formsets: DeletionTests" begin
  port_block() do
    PoetFormSet = modelformset_factory(MfsPoet; fields = "__all__", can_delete = true)
    # test_deletion: save!(commit = false) deletes nothing
    poet = create(MfsPoet; name = "test")
    data = Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0",
                "form-0-id" => string(poet.id), "form-0-name" => "test", "form-0-DELETE" => "on")
    formset = PoetFormSet(data; queryset = objects(MfsPoet))
    save!(formset; commit = false)
    @test count(objects(MfsPoet)) == 1
    save!(formset)
    @test is_valid(formset) && count(objects(MfsPoet)) == 0
    # test_add_form_deletion_when_invalid: forms marked for deletion aren't validated
    poet = create(MfsPoet; name = "test")
    data = Dict("form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0",
                "form-0-id" => string(poet.id), "form-0-name" => "test", "form-1-id" => "", "form-1-name" => "x"^1000,
                "form-2-id" => string(poet.id), "form-2-name" => "test2")
    @test !is_valid(PoetFormSet(data; queryset = objects(MfsPoet))) && count(objects(MfsPoet)) == 1
    merge!(data, Dict("form-0-DELETE" => "on", "form-1-DELETE" => "on", "form-2-DELETE" => "on"))
    formset = PoetFormSet(data; queryset = objects(MfsPoet))
    @test is_valid(formset)
    save!(formset)
    @test count(objects(MfsPoet)) == 0
    # test_change_form_deletion_when_invalid
    poet = create(MfsPoet; name = "test")
    data = Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0",
                "form-0-id" => string(poet.id), "form-0-name" => "x"^1000)
    @test !is_valid(PoetFormSet(data; queryset = objects(MfsPoet))) && count(objects(MfsPoet)) == 1
    data["form-0-DELETE"] = "on"
    formset = PoetFormSet(data; queryset = objects(MfsPoet))
    @test is_valid(formset)
    save!(formset)
    @test count(objects(MfsPoet)) == 0
    # test_outdated_deletion: a deleted form for an object that isn't there
    poet = create(MfsPoet; name = "test")
    poem = create(MfsPoem; name = "Brevity is the soul of wit", poet)
    PoemFormSet = inlineformset_factory(MfsPoet, MfsPoem; fields = "__all__", can_delete = true)
    data = Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "2", "form-0-id" => string(poem.id), "form-0-name" => "foo",
                "form-1-id" => string(poem.id + 1), "form-1-name" => "bar", "form-1-DELETE" => "on")
    formset = PoemFormSet(data; instance = poet, prefix = "form")
    @test is_valid(formset)
    save!(formset)
    @test get(MfsPoem; id = poem.id).name == "foo" && count(filter(objects(MfsPoem); poet = poet)) == 1 && !exists(filter(objects(MfsPoem); id = poem.id + 1))
    # test_deletion_not_allowed_outside_formset_queryset
    OwnerProfileFormSet = inlineformset_factory(MfsOwner, MfsOwnerProfile; can_delete = true, fields = "__all__")
    place = create(MfsPlace; name = "Sal's Place", city = "Cairo")
    owner = create(MfsOwner; name = "Sal", place)
    profile = create(MfsOwnerProfile; owner, age = 42)
    data = Dict("ownerprofile-TOTAL_FORMS" => "1", "ownerprofile-INITIAL_FORMS" => "1", "ownerprofile-MAX_NUM_FORMS" => "0",
                "ownerprofile-0-id" => string(profile.id), "ownerprofile-0-age" => string(profile.age), "ownerprofile-0-DELETE" => "on")
    formset = OwnerProfileFormSet(data; instance = owner, queryset = exclude(objects(MfsOwnerProfile); id = profile.id), prefix = "ownerprofile")
    @test is_valid(formset)
    save!(formset)
    @test exists(filter(objects(MfsOwnerProfile); id = profile.id))
    # test_deletion_not_allowed_outside_formset_queryset_editable_pk
    CustomPrimaryKeyFormSet = modelformset_factory(MfsCustomPrimaryKey; can_delete = true, fields = "__all__")
    obj = create(MfsCustomPrimaryKey; my_pk = "pk", some_field = "data")
    data = Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0",
                "form-0-my_pk" => obj.my_pk, "form-0-some_field" => obj.some_field, "form-0-DELETE" => "on")
    formset = CustomPrimaryKeyFormSet(data; queryset = exclude(objects(MfsCustomPrimaryKey); my_pk = "pk"))
    @test is_valid(formset)
    save!(formset)
    @test exists(filter(objects(MfsCustomPrimaryKey); my_pk = "pk"))
  end
end

# Django's model formset rows have no `required` attributes (a formset's forms don't use them)
mfs_author_p(i; name = nothing, id = nothing, delete = false) =
    "<p><label for=\"id_form-$i-name\">Name:</label> <input id=\"id_form-$i-name\" type=\"text\" name=\"form-$i-name\"" *
    (name === nothing ? "" : " value=\"$name\"") * " maxlength=\"100\">" *
    # (Juango puts a checkbox before its label)
    (delete ? "</p><p><input type=\"checkbox\" name=\"form-$i-DELETE\" id=\"id_form-$i-DELETE\"> <label for=\"id_form-$i-DELETE\">Delete:</label>" : "") *
    "<input type=\"hidden\" name=\"form-$i-id\"" * (id === nothing ? "" : " value=\"$id\"") * " id=\"id_form-$i-id\"></p>"

@testset "django model_formsets: ModelFormsetTest (simple save)" begin
  port_block() do
    # (test_modelformset_factory_without_fields: Juango takes all the editable fields)
    qs = objects(MfsAuthor)
    AuthorFormSet = modelformset_factory(MfsAuthor; fields = "__all__", extra = 3)
    formset = AuthorFormSet(; queryset = qs)
    @test length(formset.forms) == 3
    @test all(i -> html_eq(as_p(formset.forms[i + 1]), mfs_author_p(i)), 0:2)
    data = Dict("form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "",
                "form-0-name" => "Charles Baudelaire", "form-1-name" => "Arthur Rimbaud", "form-2-name" => "")
    formset = AuthorFormSet(data; queryset = qs)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 2
    author1, author2 = saved
    @test author1.id == get(MfsAuthor; name = "Charles Baudelaire").id && author2.id == get(MfsAuthor; name = "Arthur Rimbaud").id
    @test [a.id for a in order_by(objects(MfsAuthor), "name")] == [author2.id, author1.id]
    # editing them, with an extra form to add another
    qs = order_by(objects(MfsAuthor), "name")
    AuthorFormSet = modelformset_factory(MfsAuthor; fields = "__all__", extra = 1, can_delete = false)
    formset = AuthorFormSet(; queryset = qs)
    @test length(formset.forms) == 3
    @test html_eq(as_p(formset.forms[1]), mfs_author_p(0; name = "Arthur Rimbaud", id = author2.id)) &&
          html_eq(as_p(formset.forms[2]), mfs_author_p(1; name = "Charles Baudelaire", id = author1.id)) && html_eq(as_p(formset.forms[3]), mfs_author_p(2))
    data = Dict("form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "2", "form-MAX_NUM_FORMS" => "",
                "form-0-id" => string(author2.id), "form-0-name" => "Arthur Rimbaud", "form-1-id" => string(author1.id),
                "form-1-name" => "Charles Baudelaire", "form-2-name" => "Paul Verlaine")
    formset = AuthorFormSet(data; queryset = qs)
    @test is_valid(formset)
    saved = save!(formset)                      # (only new and changed objects)
    @test length(saved) == 1
    author3 = saved[1]
    @test author3.id == get(MfsAuthor; name = "Paul Verlaine").id
    @test [a.id for a in order_by(objects(MfsAuthor), "name")] == [author2.id, author1.id, author3.id]
    # an add form marked for deletion isn't saved
    AuthorFormSet = modelformset_factory(MfsAuthor; fields = "__all__", extra = 1, can_delete = true)
    formset = AuthorFormSet(; queryset = qs)
    @test length(formset.forms) == 4
    @test html_eq(as_p(formset.forms[1]), mfs_author_p(0; name = "Arthur Rimbaud", id = author2.id, delete = true))
    @test html_eq(as_p(formset.forms[4]), mfs_author_p(3; delete = true))
    data = Dict("form-TOTAL_FORMS" => "4", "form-INITIAL_FORMS" => "3", "form-MAX_NUM_FORMS" => "",
                "form-0-id" => string(author2.id), "form-0-name" => "Arthur Rimbaud", "form-1-id" => string(author1.id),
                "form-1-name" => "Charles Baudelaire", "form-2-id" => string(author3.id), "form-2-name" => "Paul Verlaine",
                "form-3-name" => "Walt Whitman", "form-3-DELETE" => "on")
    formset = AuthorFormSet(data; queryset = qs)
    @test is_valid(formset) && isempty(save!(formset))
    @test [a.id for a in order_by(objects(MfsAuthor), "name")] == [author2.id, author1.id, author3.id]
    # editing one record: only it is returned
    data = merge(data, Dict("form-0-name" => "Walt Whitman", "form-3-name" => "", "form-3-DELETE" => ""))
    formset = AuthorFormSet(data; queryset = qs)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].id == get(MfsAuthor; name = "Walt Whitman").id
  end
end

@model struct MfsAuthorMeeting
    name = CharField(max_length = 100)
    authors = ManyToManyField(MfsAuthor)
    created = DateField(editable = false)
    Meta(table = "mfs_authormeeting")
end
@model struct MfsPost
    title = CharField(max_length = 50, unique_for_date = :posted, blank = true)
    slug = CharField(max_length = 50, unique_for_year = :posted, blank = true)
    subtitle = CharField(max_length = 50, unique_for_month = :posted, blank = true)
    posted = DateField()
    Meta(table = "mfs_post")
end
# Django's PoetForm whose save() renames the poet: a row form with its own save hook
mfs_poet_form(; kw...) = (f = ModelForm(MfsPoet; fields = "__all__", kw...); f.name = "MfsJerkPoetForm"; f)
Juango.form_save_hook(f::Juango.Form, ::Val{:MfsJerkPoetForm}, obj) = (obj.name = "Vladimir Mayakovsky"; nothing)
redirect_stdout(devnull) do
    ms = [MfsAuthorMeeting, through(MfsAuthorMeeting, :authors), MfsPost]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_formsets: ModelFormsetTest (commit = false, max_num, min_num, custom forms)" begin
  port_block() do
    # test_commit_false: save!(commit = false), then save_m2m!
    author1, author2, author3 = (create(MfsAuthor; name = n) for n in ("Charles Baudelaire", "Paul Verlaine", "Walt Whitman"))
    meeting = create(MfsAuthorMeeting; name = "meeting", created = Dates.today())
    set!(meeting.authors, collect(objects(MfsAuthor)))
    author4 = create(MfsAuthor; name = "John Steinbeck")
    AuthorMeetingFormSet = modelformset_factory(MfsAuthorMeeting; fields = "__all__", extra = 1, can_delete = true)
    data = Dict{String,Any}("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "",
                            "form-0-id" => string(meeting.id), "form-0-name" => "2nd Tuesday of the Week Meeting",
                            "form-0-authors" => [string(a.id) for a in (author2, author1, author3, author4)],
                            "form-1-name" => "", "form-1-authors" => "", "form-1-DELETE" => "")
    formset = AuthorMeetingFormSet(data; queryset = objects(MfsAuthorMeeting))
    @test is_valid(formset)
    instances = save!(formset; commit = false)
    for instance in instances
        instance.created = Dates.today()
        save!(instance)
    end
    save_m2m!(formset)
    @test [a.id for a in instances[1].authors] == [author1.id, author4.id, author2.id, author3.id]     # (by the authors' ordering, name)
    for x in collect(objects(MfsAuthor)); delete!(x); end
    # test_max_num: all the objects are shown, but no more extra forms than max_num allows
    a1, a2, a3 = (create(MfsAuthor; name = n) for n in ("Charles Baudelaire", "Paul Verlaine", "Walt Whitman"))
    qs = order_by(objects(MfsAuthor), "name")
    for (max_num, nforms, nextra) in ((nothing, 6, 3), (4, 4, 1), (0, 3, 0))
        formset = modelformset_factory(MfsAuthor; fields = "__all__", max_num, extra = 3)(; queryset = qs)
        @test (max_num, length(formset.forms), length(Juango.extra_forms(formset))) == (max_num, nforms, nextra)
    end
    for max_num in (nothing, 0, 4)
        @test [a.id for a in Juango.get_queryset(modelformset_factory(MfsAuthor; fields = "__all__", max_num)(; queryset = qs))] == [a1.id, a2.id, a3.id]
    end
    # test_min_num: added to extra
    for (min_num, extra, n) in ((0, 0, 0), (1, 0, 1), (1, 1, 2))
        @test length(modelformset_factory(MfsAuthor; fields = "__all__", min_num, extra)(; queryset = none(MfsAuthor)).forms) == n
    end
    # test_min_num_with_existing
    @test length(modelformset_factory(MfsAuthor; fields = "__all__", extra = 0, min_num = 1)(; queryset = filter(objects(MfsAuthor); id = a1.id)).forms) == 1
    # test_custom_save_method: a row form whose save! changes the name (Juango: form_save_hook)
    data = Dict("form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "",
                "form-0-name" => "Walt Whitman", "form-1-name" => "Charles Baudelaire", "form-2-name" => "")
    formset = modelformset_factory(MfsPoet; fields = "__all__", form = mfs_poet_form)(data; queryset = objects(MfsPoet))
    @test is_valid(formset)
    poets = save!(formset)
    @test length(poets) == 2 && all(p -> p.name == "Vladimir Mayakovsky", poets)
    # test_custom_form: the row form's own fields
    post_form1(; kw...) = ModelForm(MfsPost; fields = (:title, :posted), kw...)
    post_form2(; kw...) = ModelForm(MfsPost; exclude = (:subtitle,), kw...)
    @test !(:subtitle in mf_names(modelformset_factory(MfsPost; form = post_form1)().forms[1]))
    @test !(:subtitle in mf_names(modelformset_factory(MfsPost; form = post_form2)().forms[1]))
    # test_custom_queryset_init (Juango: the queryset is the formset's keyword)
    @test length(Juango.get_queryset(modelformset_factory(MfsAuthor; fields = "__all__")(; queryset = filter(objects(MfsAuthor); name__startswith = "Charles")))) == 1
  end
end

@testset "django model_formsets: ModelFormsetTest (model inheritance)" begin
  port_block() do
    # (Django's child has a hidden author_ptr; Juango's model formset rows have a hidden id)
    BetterAuthorFormSet = modelformset_factory(MfsBetterAuthor; fields = "__all__")
    better_p(i; name = nothing, speed = nothing, id = nothing) =
        "<p><label for=\"id_form-$i-name\">Name:</label> <input id=\"id_form-$i-name\" type=\"text\" name=\"form-$i-name\"" *
        (name === nothing ? "" : " value=\"$name\"") * " maxlength=\"100\"></p>" *
        "<p><label for=\"id_form-$i-write_speed\">Write speed:</label> <input type=\"number\" name=\"form-$i-write_speed\"" *
        (speed === nothing ? "" : " value=\"$speed\"") * " id=\"id_form-$i-write_speed\">" *
        "<input type=\"hidden\" name=\"form-$i-id\"" * (id === nothing ? "" : " value=\"$id\"") * " id=\"id_form-$i-id\"></p>"
    formset = BetterAuthorFormSet()
    @test length(formset.forms) == 1 && html_eq(as_p(formset.forms[1]), better_p(0))
    formset = BetterAuthorFormSet(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "",
                                       "form-0-id" => "", "form-0-name" => "Ernest Hemingway", "form-0-write_speed" => "10"))
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].id == get(MfsBetterAuthor; name = "Ernest Hemingway").id
    hemingway_id = saved[1].id
    formset = BetterAuthorFormSet()
    @test length(formset.forms) == 2 && html_eq(as_p(formset.forms[1]), better_p(0; name = "Ernest Hemingway", speed = 10, id = hemingway_id)) &&
          html_eq(as_p(formset.forms[2]), better_p(1))
    formset = BetterAuthorFormSet(Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "",
                                       "form-0-id" => string(hemingway_id), "form-0-name" => "Ernest Hemingway", "form-0-write_speed" => "10",
                                       "form-1-id" => "", "form-1-name" => "", "form-1-write_speed" => ""))
    @test is_valid(formset) && isempty(save!(formset))
  end
end

@model struct MfsBookWithCustomPK
    my_pk = DecimalField(max_digits = 5, decimal_places = 0, primary_key = true)
    author = ForeignKey(MfsAuthor, on_delete = :CASCADE)
    title = CharField(max_length = 100)
    Meta(table = "mfs_bookwithcustompk")
end
@model struct MfsEditor
    name = CharField(max_length = 100)
    Meta(table = "mfs_editor")
end
@model struct MfsBookWithOptionalAltEditor
    author = ForeignKey(MfsAuthor, on_delete = :CASCADE)
    alt_editor = ForeignKey(MfsEditor, on_delete = :SET_NULL, blank = true, null = true)
    title = CharField(max_length = 100)
    Meta(table = "mfs_bookwithoptionalalteditor", unique_together = [(:author, :title, :alt_editor)])
end
@model struct MfsAlternateBook <: MfsBook
    notes = CharField(max_length = 100)
    Meta(table = "mfs_alternatebook")
end
redirect_stdout(devnull) do
    ms = [MfsBookWithCustomPK, MfsEditor, MfsBookWithOptionalAltEditor, MfsAlternateBook]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
# a row of an inline formset of an author's books: its title, the parent's key and the row's id, hidden
mfs_book_p(p, i, author_id; title = nothing, id = nothing) =
    "<p><label for=\"id_$p-$i-title\">Title:</label> <input id=\"id_$p-$i-title\" type=\"text\" name=\"$p-$i-title\"" *
    (title === nothing ? "" : " value=\"$title\"") * " maxlength=\"100\">" *
    "<input type=\"hidden\" name=\"$p-$i-author\"" * (author_id === nothing ? "" : " value=\"$author_id\"") * " id=\"id_$p-$i-author\">" *
    "<input type=\"hidden\" name=\"$p-$i-id\"" * (id === nothing ? "" : " value=\"$id\"") * " id=\"id_$p-$i-id\"></p>"

@testset "django model_formsets: ModelFormsetTest (inline formsets)" begin
  port_block() do
    # test_inline_formsets (Juango's default prefix is the reverse name, mfsbook_set)
    AuthorBooksFormSet = inlineformset_factory(MfsAuthor, MfsBook; can_delete = false, extra = 3, fields = "__all__")
    author = create(MfsAuthor; name = "Charles Baudelaire")
    formset = AuthorBooksFormSet(; instance = author)
    @test length(formset.forms) == 3 && all(i -> html_eq(as_p(formset.forms[i + 1]), mfs_book_p("mfsbook_set", i, author.id)), 0:2)
    data = Dict("mfsbook_set-TOTAL_FORMS" => "3", "mfsbook_set-INITIAL_FORMS" => "0", "mfsbook_set-MAX_NUM_FORMS" => "",
                "mfsbook_set-0-title" => "Les Fleurs du Mal", "mfsbook_set-1-title" => "", "mfsbook_set-2-title" => "")
    formset = AuthorBooksFormSet(data; instance = author)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1
    book1 = saved[1]
    @test book1.id == get(MfsBook; title = "Les Fleurs du Mal").id && [b.id for b in filter(objects(MfsBook); author)] == [book1.id]
    # an edit form for each book, and extra forms to add more
    AuthorBooksFormSet = inlineformset_factory(MfsAuthor, MfsBook; can_delete = false, extra = 2, fields = "__all__")
    formset = AuthorBooksFormSet(; instance = author)
    @test length(formset.forms) == 3 && html_eq(as_p(formset.forms[1]), mfs_book_p("mfsbook_set", 0, author.id; title = "Les Fleurs du Mal", id = book1.id)) &&
          html_eq(as_p(formset.forms[2]), mfs_book_p("mfsbook_set", 1, author.id)) && html_eq(as_p(formset.forms[3]), mfs_book_p("mfsbook_set", 2, author.id))
    data = Dict("mfsbook_set-TOTAL_FORMS" => "3", "mfsbook_set-INITIAL_FORMS" => "1", "mfsbook_set-MAX_NUM_FORMS" => "",
                "mfsbook_set-0-id" => string(book1.id), "mfsbook_set-0-title" => "Les Fleurs du Mal",
                "mfsbook_set-1-title" => "Les Paradis Artificiels", "mfsbook_set-2-title" => "")
    formset = AuthorBooksFormSet(data; instance = author)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1
    book2 = saved[1]
    @test book2.id == get(MfsBook; title = "Les Paradis Artificiels").id
    @test [b.id for b in order_by(filter(objects(MfsBook); author), "title")] == [book1.id, book2.id]
    # a parent key that isn't the parent's is an error
    bad = merge(data, Dict("mfsbook_set-0-author" => string(author.id + 1000)))
    formset = AuthorBooksFormSet(bad; instance = author)
    @test !is_valid(formset) && Juango.errors(formset)[1][:author] == ["The inline value did not match the parent instance."]
    # test_inline_formsets_save_as_new: the rows are new objects for another parent
    data = Dict("mfsbook_set-TOTAL_FORMS" => "3", "mfsbook_set-INITIAL_FORMS" => "2", "mfsbook_set-MAX_NUM_FORMS" => "",
                "mfsbook_set-0-id" => string(book1.id), "mfsbook_set-0-title" => "Les Fleurs du Mal",
                "mfsbook_set-1-id" => string(book2.id), "mfsbook_set-1-title" => "Les Paradis Artificiels", "mfsbook_set-2-title" => "")
    @test is_valid(AuthorBooksFormSet(data; instance = MfsAuthor(), save_as_new = true))
    new_author = create(MfsAuthor; name = "Charles Baudelaire")
    saved = save!(AuthorBooksFormSet(data; instance = new_author, save_as_new = true))
    @test length(saved) == 2 && [b.title for b in saved] == ["Les Fleurs du Mal", "Les Paradis Artificiels"] &&
          all(b -> b.author.id == new_author.id && !(b.id in (book1.id, book2.id)), saved)
    @test count(filter(objects(MfsBook); author)) == 2                        # (the old author's are as they were)
    # a custom prefix, and no parent
    formset = AuthorBooksFormSet(; prefix = "test")
    @test length(formset.forms) == 2 && html_eq(as_p(formset.forms[1]), mfs_book_p("test", 0, nothing)) && html_eq(as_p(formset.forms[2]), mfs_book_p("test", 1, nothing))
  end
end

@testset "django model_formsets: ModelFormsetTest (inline formsets with custom keys and inheritance)" begin
  port_block() do
    author = create(MfsAuthor; name = "Charles Baudelaire")
    # test_inline_formsets_with_custom_pk: the primary key is a field on the form
    AuthorBooksFormSet2 = inlineformset_factory(MfsAuthor, MfsBookWithCustomPK; can_delete = false, extra = 1, fields = "__all__")
    formset = AuthorBooksFormSet2(; instance = author)
    p = "mfsbookwithcustompk_set"
    @test length(formset.forms) == 1
    @test html_eq(as_p(formset.forms[1]),
                  "<p><label for=\"id_$p-0-my_pk\">My pk:</label> <input id=\"id_$p-0-my_pk\" type=\"number\" name=\"$p-0-my_pk\" step=\"1\"></p>" *
                  "<p><label for=\"id_$p-0-title\">Title:</label> <input id=\"id_$p-0-title\" type=\"text\" name=\"$p-0-title\" maxlength=\"100\">" *
                  "<input type=\"hidden\" name=\"$p-0-author\" value=\"$(author.id)\" id=\"id_$p-0-author\"></p>")
    formset = AuthorBooksFormSet2(Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "",
                                       "$p-0-my_pk" => "77777", "$p-0-title" => "Les Fleurs du Mal"); instance = author)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].my_pk == Decimal("77777")
    @test only(collect(filter(objects(MfsBookWithCustomPK); author))).title == "Les Fleurs du Mal"
    # test_inline_formsets_with_multi_table_inheritance (Juango's row has a hidden id, Django's a book_ptr)
    AuthorBooksFormSet3 = inlineformset_factory(MfsAuthor, MfsAlternateBook; can_delete = false, extra = 1, fields = "__all__")
    formset = AuthorBooksFormSet3(; instance = author)
    p = "mfsalternatebook_set"
    @test length(formset.forms) == 1
    @test html_eq(as_p(formset.forms[1]),
                  "<p><label for=\"id_$p-0-title\">Title:</label> <input id=\"id_$p-0-title\" type=\"text\" name=\"$p-0-title\" maxlength=\"100\"></p>" *
                  "<p><label for=\"id_$p-0-notes\">Notes:</label> <input id=\"id_$p-0-notes\" type=\"text\" name=\"$p-0-notes\" maxlength=\"100\">" *
                  "<input type=\"hidden\" name=\"$p-0-author\" value=\"$(author.id)\" id=\"id_$p-0-author\">" *
                  "<input type=\"hidden\" name=\"$p-0-id\" id=\"id_$p-0-id\"></p>")
    formset = AuthorBooksFormSet3(Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "",
                                       "$p-0-title" => "Flowers of Evil", "$p-0-notes" => "English translation of Les Fleurs du Mal"); instance = author)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].title == "Flowers of Evil" && saved[1].notes == "English translation of Les Fleurs du Mal"
    # test_inline_formsets_with_nullable_unique_together: a null in a unique_together doesn't clash
    AuthorBooksFormSet4 = inlineformset_factory(MfsAuthor, MfsBookWithOptionalAltEditor; can_delete = false, extra = 2, fields = "__all__")
    p = "mfsbookwithoptionalalteditor_set"
    formset = AuthorBooksFormSet4(Dict("$p-TOTAL_FORMS" => "2", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "",
                                       "$p-0-author" => string(author.id), "$p-0-title" => "Les Fleurs du Mal",
                                       "$p-1-author" => string(author.id), "$p-1-title" => "Les Fleurs du Mal"); instance = author)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 2 && all(b -> b.author.id == author.id && b.title == "Les Fleurs du Mal", saved)
  end
end

# Django's PoemForm whose save() renames the poem
mfs_poem_form(; kw...) = (f = ModelForm(MfsPoem; fields = "__all__", kw...); f.name = "MfsJerkPoemForm"; f)
Juango.form_save_hook(f::Juango.Form, ::Val{:MfsJerkPoemForm}, obj) = (obj.name = "Brooklyn Bridge"; nothing)

@testset "django model_formsets: ModelFormsetTest (inline formsets: custom save, custom queryset)" begin
  port_block() do
    AuthorBooksFormSet = inlineformset_factory(MfsAuthor, MfsBook; can_delete = false, extra = 2, fields = "__all__")
    author = create(MfsAuthor; name = "Charles Baudelaire")
    book1 = create(MfsBook; author, title = "Les Paradis Artificiels")
    book2 = create(MfsBook; author, title = "Les Fleurs du Mal")
    book3 = create(MfsBook; author, title = "Flowers of Evil")
    # test_inline_formsets_with_custom_save_method
    PoemFormSet = inlineformset_factory(MfsPoet, MfsPoem; form = mfs_poem_form, fields = "__all__")
    poet = create(MfsPoet; name = "Vladimir Mayakovsky")
    formset = PoemFormSet(Dict("mfspoem_set-TOTAL_FORMS" => "3", "mfspoem_set-INITIAL_FORMS" => "0", "mfspoem_set-MAX_NUM_FORMS" => "",
                               "mfspoem_set-0-name" => "The Cloud in Trousers", "mfspoem_set-1-name" => "I", "mfspoem_set-2-name" => ""); instance = poet)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 2 && all(p -> p.name == "Brooklyn Bridge", saved)
    # a custom queryset for the inline formset
    p = "mfsbook_set"
    custom_qs = order_by(objects(MfsBook), "-title")
    formset = AuthorBooksFormSet(; instance = author, queryset = custom_qs)
    @test length(formset.forms) == 5
    bs = [book1, book2, book3]
    @test all(i -> html_eq(as_p(formset.forms[i]), mfs_book_p(p, i - 1, author.id; title = bs[i].title, id = bs[i].id)), 1:3)
    @test html_eq(as_p(formset.forms[4]), mfs_book_p(p, 3, author.id)) && html_eq(as_p(formset.forms[5]), mfs_book_p(p, 4, author.id))
    data = Dict("$p-TOTAL_FORMS" => "5", "$p-INITIAL_FORMS" => "3", "$p-MAX_NUM_FORMS" => "",
                "$p-0-id" => string(book1.id), "$p-0-title" => "Les Paradis Artificiels", "$p-1-id" => string(book2.id), "$p-1-title" => "Les Fleurs du Mal",
                "$p-2-id" => string(book3.id), "$p-2-title" => "Flowers of Evil", "$p-3-title" => "Revue des deux mondes", "$p-4-title" => "")
    @test is_valid(AuthorBooksFormSet(data; instance = author, queryset = custom_qs))
    custom_qs = filter(objects(MfsBook); title__startswith = "F")
    formset = AuthorBooksFormSet(; instance = author, queryset = custom_qs)
    @test html_eq(as_p(formset.forms[1]), mfs_book_p(p, 0, author.id; title = "Flowers of Evil", id = book3.id)) &&
          html_eq(as_p(formset.forms[2]), mfs_book_p(p, 1, author.id)) && html_eq(as_p(formset.forms[3]), mfs_book_p(p, 2, author.id))
    data = Dict("$p-TOTAL_FORMS" => "3", "$p-INITIAL_FORMS" => "1", "$p-MAX_NUM_FORMS" => "", "$p-0-id" => string(book3.id),
                "$p-0-title" => "Flowers of Evil", "$p-1-title" => "Revue des deux mondes", "$p-2-title" => "")
    @test is_valid(AuthorBooksFormSet(data; instance = author, queryset = custom_qs))
  end
end

@model struct MfsLocation
    place = ForeignKey(MfsPlace, on_delete = :CASCADE, unique = true)
    lat = CharField(max_length = 100)
    lon = CharField(max_length = 100)
    Meta(table = "mfs_location")
end
@model struct MfsProduct
    slug = SlugField(unique = true)
    Meta(table = "mfs_product", verbose_name = "product")
end
@model struct MfsPrice
    price = DecimalField(max_digits = 10, decimal_places = 2)
    quantity = PositiveIntegerField()
    Meta(table = "mfs_price", unique_together = [(:price, :quantity)], verbose_name = "price")
end
@model struct MfsRepository
    name = CharField(max_length = 25)
    Meta(table = "mfs_repository")
end
@model struct MfsRevision
    repository = ForeignKey(MfsRepository, on_delete = :CASCADE)
    revision = CharField(max_length = 40)
    Meta(table = "mfs_revision", unique_together = [(:repository, :revision)], verbose_name = "revision")
end
@model struct MfsPerson
    name = CharField(max_length = 128)
    Meta(table = "mfs_person")
end
@model struct MfsMembership
    person = ForeignKey(MfsPerson, on_delete = :CASCADE)
    date_joined = DateTimeField(default = () -> Dates.now())
    karma = IntegerField()
    Meta(table = "mfs_membership")
end
@model struct MfsTeam
    name = CharField(max_length = 100)
    Meta(table = "mfs_team")
end
@model struct MfsPlayer
    team = ForeignKey(MfsTeam, on_delete = :SET_NULL, null = true)
    name = CharField(max_length = 100)
    Meta(table = "mfs_player")
end
redirect_stdout(devnull) do
    ms = [MfsLocation, MfsProduct, MfsPrice, MfsRepository, MfsRevision, MfsPerson, MfsMembership, MfsTeam, MfsPlayer]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_formsets: ModelFormsetTest (unique checks, limits, callable defaults)" begin
  port_block() do
    # test_inline_formsets_with_wrong_fk_name (#23451)
    @test (try inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", fk = :title); "" catch e; e isa ArgumentError ? e.msg : rethrow() end) ==
          "fk_name 'title' is not a ForeignKey to 'MfsAuthor'."
    # test_unique_true_enforces_max_num_one: a unique foreign key has at most one row
    place = create(MfsPlace; name = "Giordanos", city = "Chicago")
    FormSet = inlineformset_factory(MfsPlace, MfsLocation; can_delete = false, fields = "__all__")
    formset = FormSet(; instance = place)
    p = "mfslocation_set"
    @test formset.max_num == 1 && length(formset.forms) == 1
    @test html_eq(as_p(formset.forms[1]),
                  "<p><label for=\"id_$p-0-lat\">Lat:</label> <input id=\"id_$p-0-lat\" type=\"text\" name=\"$p-0-lat\" maxlength=\"100\"></p>" *
                  "<p><label for=\"id_$p-0-lon\">Lon:</label> <input id=\"id_$p-0-lon\" type=\"text\" name=\"$p-0-lon\" maxlength=\"100\">" *
                  "<input type=\"hidden\" name=\"$p-0-place\" value=\"$(place.id)\" id=\"id_$p-0-place\">" *
                  "<input type=\"hidden\" name=\"$p-0-id\" id=\"id_$p-0-id\"></p>")
    # test_unique_validation
    FormSet = modelformset_factory(MfsProduct; fields = "__all__", extra = 1)
    data = Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "", "form-0-slug" => "car-red")
    formset = FormSet(data)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].slug == "car-red"
    formset = FormSet(data)
    @test !is_valid(formset) && Juango.errors(formset) == [Dict(:slug => ["Product with this Slug already exists."])]
    # test_modelformset_validate_max_flag (MAX_NUM_FORMS in the data is ignored)
    data = Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "2",
                "form-0-price" => "12.00", "form-0-quantity" => "1", "form-1-price" => "24.00", "form-1-quantity" => "2")
    formset = modelformset_factory(MfsPrice; fields = "__all__", extra = 1, max_num = 1, validate_max = true)(data)
    @test !is_valid(formset) && non_form_errors(formset) == ["Please submit at most 1 form."]
    @test is_valid(modelformset_factory(MfsPrice; fields = "__all__", extra = 1, max_num = 1)(data))
    # test_modelformset_min_num_equals_max_num_less_than, _more_than
    minmax = modelformset_factory(MfsProduct; fields = "__all__", extra = 1, max_num = 2, validate_max = true, min_num = 2, validate_min = true)
    formset = minmax(Dict("form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "2",
                          "form-0-slug" => "car-red", "form-1-slug" => "car-blue", "form-2-slug" => "car-black"))
    @test !is_valid(formset) && non_form_errors(formset) == ["Please submit at most 2 forms."]
    formset = minmax(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "2", "form-0-slug" => "car-red"))
    @test !is_valid(formset) && non_form_errors(formset) == ["Please submit at least 2 forms."]
    # test_unique_together_validation
    FormSet = modelformset_factory(MfsPrice; fields = "__all__", extra = 1)
    data = Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "", "form-0-price" => "12.00", "form-0-quantity" => "1")
    formset = FormSet(data)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].price == Decimal("12.00") && saved[1].quantity == 1
    formset = FormSet(data)
    @test !is_valid(formset) && Juango.errors(formset) == [Dict(:__all__ => ["Price with this Price and Quantity already exists."])]
    # test_unique_together_with_inlineformset_factory (#8882, #9494: checked with the parent even when the form leaves the key out)
    repository = create(MfsRepository; name = "Test Repo")
    FormSet = inlineformset_factory(MfsRepository, MfsRevision; extra = 1, fields = "__all__")
    p = "mfsrevision_set"
    data = Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "", "$p-0-repository" => string(repository.id),
                "$p-0-revision" => "146239817507f148d448db38840db7c3cbf47c76", "$p-0-DELETE" => "")
    formset = FormSet(data; instance = repository)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].repository.id == repository.id && saved[1].revision == "146239817507f148d448db38840db7c3cbf47c76"
    formset = FormSet(data; instance = repository)
    @test !is_valid(formset) && Juango.errors(formset) == [Dict(:__all__ => ["Revision with this Repository and Revision already exists."])]
    @test !is_valid(inlineformset_factory(MfsRepository, MfsRevision; fields = (:revision,), extra = 1)(data; instance = repository))
    # test_callable_defaults (#7975): a callable default's initial value is in a hidden input, so an untouched extra form isn't changed
    person = create(MfsPerson; name = "Ringo")
    FormSet = inlineformset_factory(MfsPerson, MfsMembership; can_delete = false, extra = 1, fields = "__all__")
    formset = FormSet(; instance = person)
    @test length(formset.forms) == 1
    html = as_p(formset.forms[1]).s
    @test occursin("name=\"initial-mfsmembership_set-0-date_joined\"", html)
    @test occursin(Regex("name=\"mfsmembership_set-0-person\"[^>]* value=\"$(person.id)\""), html)
    now_ = Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")
    p = "mfsmembership_set"
    data = Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "", "$p-0-date_joined" => now_,
                "initial-$p-0-date_joined" => now_, "$p-0-karma" => "")
    @test is_valid(FormSet(data; instance = person))
    later = Dates.format(Dates.now() + Day(1), "yyyy-mm-dd HH:MM:SS")
    @test !is_valid(FormSet(merge(data, Dict("$p-0-date_joined" => later)); instance = person))
    # test_inlineformset_factory_with_null_fk (#9462)
    team = create(MfsTeam; name = "Red Vipers")
    create(MfsPlayer; name = "Timmy")
    create(MfsPlayer; name = "Bobby", team)
    PlayerInlineFormSet = inlineformset_factory(MfsTeam, MfsPlayer; fields = "__all__")
    @test isempty(Juango.get_queryset(PlayerInlineFormSet()))
    players = Juango.get_queryset(PlayerInlineFormSet(; instance = team))
    @test length(players) == 1 && players[1].team.id == team.id && players[1].name == "Bobby"
  end
end

@testset "django model_formsets: ModelFormsetTest (custom primary keys)" begin
  port_block() do
    # test_custom_pk: a model's own primary key is a field on the form, with no hidden id
    formset = modelformset_factory(MfsCustomPrimaryKey; fields = "__all__")()
    @test length(formset.forms) == 1
    @test html_eq(as_p(formset.forms[1]),
                  "<p><label for=\"id_form-0-my_pk\">My pk:</label> <input id=\"id_form-0-my_pk\" type=\"text\" name=\"form-0-my_pk\" maxlength=\"10\"></p>" *
                  "<p><label for=\"id_form-0-some_field\">Some field:</label> <input id=\"id_form-0-some_field\" type=\"text\" name=\"form-0-some_field\" maxlength=\"100\"></p>")
    # (Django's Owner has an AutoField named auto_id; Juango's automatic key is always id)
    place = create(MfsPlace; name = "Giordanos", city = "Chicago")
    FormSet = inlineformset_factory(MfsPlace, MfsOwner; extra = 2, can_delete = false, fields = "__all__")
    p = "mfsowner_set"
    owner_p(i; name = nothing, id = nothing) =
        "<p><label for=\"id_$p-$i-name\">Name:</label> <input id=\"id_$p-$i-name\" type=\"text\" name=\"$p-$i-name\"" *
        (name === nothing ? "" : " value=\"$name\"") * " maxlength=\"100\">" *
        "<input type=\"hidden\" name=\"$p-$i-place\" value=\"$(place.id)\" id=\"id_$p-$i-place\">" *
        "<input type=\"hidden\" name=\"$p-$i-id\"" * (id === nothing ? "" : " value=\"$id\"") * " id=\"id_$p-$i-id\"></p>"
    formset = FormSet(; instance = place)
    @test length(formset.forms) == 2 && html_eq(as_p(formset.forms[1]), owner_p(0)) && html_eq(as_p(formset.forms[2]), owner_p(1))
    formset = FormSet(Dict("$p-TOTAL_FORMS" => "2", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "",
                           "$p-0-id" => "", "$p-0-name" => "Joe Perry", "$p-1-id" => "", "$p-1-name" => ""); instance = place)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].name == "Joe Perry" && saved[1].place.name == "Giordanos"
    owner1 = saved[1]
    formset = FormSet(; instance = place)
    @test length(formset.forms) == 3 && html_eq(as_p(formset.forms[1]), owner_p(0; name = "Joe Perry", id = owner1.id)) &&
          html_eq(as_p(formset.forms[2]), owner_p(1)) && html_eq(as_p(formset.forms[3]), owner_p(2))
    formset = FormSet(Dict("$p-TOTAL_FORMS" => "3", "$p-INITIAL_FORMS" => "1", "$p-MAX_NUM_FORMS" => "",
                           "$p-0-id" => string(owner1.id), "$p-0-name" => "Joe Perry", "$p-1-id" => "", "$p-1-name" => "Jack Berry",
                           "$p-2-id" => "", "$p-2-name" => ""); instance = place)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].name == "Jack Berry" && saved[1].place.name == "Giordanos"
    # a one-to-one child: one row at most (Django's OwnerProfile has the key as its primary key; Juango's has an id)
    FormSet = inlineformset_factory(MfsOwner, MfsOwnerProfile; max_num = 1, can_delete = false, fields = "__all__")
    p = "mfsownerprofile"
    profile_p(age; id = nothing) = "<p><label for=\"id_$p-0-age\">Age:</label> <input type=\"number\" name=\"$p-0-age\"" *
        (age === nothing ? "" : " value=\"$age\"") * " id=\"id_$p-0-age\" min=\"0\">" *
        "<input type=\"hidden\" name=\"$p-0-owner\" value=\"$(owner1.id)\" id=\"id_$p-0-owner\">" *
        "<input type=\"hidden\" name=\"$p-0-id\"" * (id === nothing ? "" : " value=\"$id\"") * " id=\"id_$p-0-id\"></p>"
    formset = FormSet(; instance = owner1)
    @test formset.max_num == 1 && length(formset.forms) == 1 && html_eq(as_p(formset.forms[1]), profile_p(nothing))
    formset = FormSet(Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "1", "$p-0-owner" => "", "$p-0-age" => "54");
                      instance = owner1)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].owner.id == owner1.id && saved[1].age == 54
    profile1 = saved[1]
    formset = FormSet(; instance = owner1)
    @test length(formset.forms) == 1 && html_eq(as_p(formset.forms[1]), profile_p(54; id = profile1.id))
    formset = FormSet(Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "1", "$p-MAX_NUM_FORMS" => "1", "$p-0-owner" => string(owner1.id),
                           "$p-0-id" => string(profile1.id), "$p-0-age" => "55"); instance = owner1)
    @test is_valid(formset)
    saved = save!(formset)
    @test length(saved) == 1 && saved[1].owner.id == owner1.id && saved[1].age == 55
  end
end

@testset "django model_formsets: ModelFormsetTest (has_changed, duplicates, row ids, edit_only)" begin
  port_block() do
    # test_model_formset_with_initial_model_instance (#18898): an object as initial is its key
    john_milton = create(MfsPoet; name = "John Milton")
    formset = modelformset_factory(MfsPoem; fields = "__all__")(Dict("form-TOTAL_FORMS" => 1, "form-INITIAL_FORMS" => 0, "form-MAX_NUM_FORMS" => "",
                                                                    "form-0-name" => "", "form-0-poet" => string(john_milton.id));
                                                               initial = [Dict(:poet => john_milton)])
    @test !has_changed(Juango.extra_forms(formset)[1])
    # test_model_formset_with_initial_queryset: objects as initial are their keys
    create(MfsAuthor; name = "Charles Baudelaire")
    formset = modelformset_factory(MfsAuthorMeeting; fields = "__all__")(Dict("form-TOTAL_FORMS" => 1, "form-INITIAL_FORMS" => 0, "form-MAX_NUM_FORMS" => "",
                                                                             "form-0-name" => "", "form-0-created" => "",
                                                                             "form-0-authors" => [string(a.id) for a in objects(MfsAuthor)]);
                                                                        initial = [Dict(:authors => collect(objects(MfsAuthor)))])
    @test !has_changed(Juango.extra_forms(formset)[1])
    # (test_get_queryset_*: Django's query internals)
    # test_prevent_duplicates_from_with_the_same_formset
    dup(fs) = (!is_valid(fs), fs.non_form_errors)
    formset = modelformset_factory(MfsProduct; fields = "__all__", extra = 2)(Dict("form-TOTAL_FORMS" => 2, "form-INITIAL_FORMS" => 0, "form-MAX_NUM_FORMS" => "",
                                                                                 "form-0-slug" => "red_car", "form-1-slug" => "red_car"))
    @test dup(formset) == (true, ["Please correct the duplicate data for slug."])
    prices = Dict("form-TOTAL_FORMS" => 2, "form-INITIAL_FORMS" => 0, "form-MAX_NUM_FORMS" => "", "form-0-price" => "25", "form-0-quantity" => "7",
                  "form-1-price" => "25", "form-1-quantity" => "7")
    @test dup(modelformset_factory(MfsPrice; fields = "__all__", extra = 2)(prices)) ==
          (true, ["Please correct the duplicate data for price and quantity, which must be unique."])
    @test is_valid(modelformset_factory(MfsPrice; fields = (:price,), extra = 2)(Dict("form-TOTAL_FORMS" => 2, "form-INITIAL_FORMS" => 0, "form-MAX_NUM_FORMS" => "",
                                                                                     "form-0-price" => "24", "form-1-price" => "24")))
    author = create(MfsAuthor; name = "Charles Baudelaire")
    books = [create(MfsBook; author, title = t) for t in ("Les Paradis Artificiels", "Les Fleurs du Mal", "Flowers of Evil")]
    p = "mfsbook_set"
    formset = inlineformset_factory(MfsAuthor, MfsBook; extra = 0, fields = "__all__")(
        Dict("$p-TOTAL_FORMS" => "2", "$p-INITIAL_FORMS" => "2", "$p-MAX_NUM_FORMS" => "",
             "$p-0-id" => string(books[1].id), "$p-0-title" => "The 2008 Election", "$p-1-id" => string(books[2].id), "$p-1-title" => "The 2008 Election");
        instance = author)
    @test dup(formset) == (true, ["Please correct the duplicate data for title."])
    @test Juango.errors(formset) == [Dict(), Dict(:__all__ => ["Please correct the duplicate values below."])]
    PostFormSet = modelformset_factory(MfsPost; fields = "__all__", extra = 2)
    posts(k, v1, d1, v2, d2) = Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "",
                                    "form-0-$k" => v1, "form-0-posted" => d1, "form-1-$k" => v2, "form-1-posted" => d2)
    formset = PostFormSet(posts("title", "blah", "2009-01-01", "blah", "2009-01-01"))
    @test dup(formset) == (true, ["Please correct the duplicate data for title which must be unique for the date in posted."])
    @test Juango.errors(formset) == [Dict(), Dict(:__all__ => ["Please correct the duplicate values below."])]
    @test dup(PostFormSet(posts("slug", "foo", "2009-01-01", "foo", "2009-08-02"))) ==
          (true, ["Please correct the duplicate data for slug which must be unique for the year in posted."])
    @test dup(PostFormSet(posts("subtitle", "foo", "2009-01-01", "foo", "2009-01-31"))) ==
          (true, ["Please correct the duplicate data for subtitle which must be unique for the month in posted."])
    # test_prevent_change_outer_model_and_create_invalid_data: a row for an object outside the queryset changes nothing
    charles, walt = create(MfsAuthor; name = "Charles"), create(MfsAuthor; name = "Walt")
    formset = modelformset_factory(MfsAuthor; fields = "__all__")(
        Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "2", "form-MAX_NUM_FORMS" => "", "form-0-id" => string(charles.id),
             "form-0-name" => "Charles", "form-1-id" => string(walt.id), "form-1-name" => "Changed name");
        queryset = filter(objects(MfsAuthor); id__in = [charles.id]))
    n = count(objects(MfsAuthor))
    @test is_valid(formset)
    save!(formset)
    @test get(MfsAuthor; id = walt.id).name == "Walt" && count(objects(MfsAuthor)) == n
    # (test_overridden_add_prefix, test_form_initialized_once_with_default_add_prefix: Django's form internals)
    # test_validation_without_id, test_validation_with_invalid_id, test_validation_with_nonexistent_id
    AuthorFormSet = modelformset_factory(MfsAuthor; fields = "__all__")
    rows(id) = merge(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "", "form-0-name" => "Charles"),
                     id === nothing ? Dict() : Dict("form-0-id" => id))
    @test Juango.errors(AuthorFormSet(rows(nothing))) == [Dict(:id => ["This field is required."])]
    @test Juango.errors(AuthorFormSet(rows("abc"))) == [Dict(:id => ["Select a valid choice. That choice is not one of the available choices."])]
    @test Juango.errors(AuthorFormSet(rows("12345"))) == [Dict(:id => ["Select a valid choice. That choice is not one of the available choices."])]
    @test Juango.initial_form_count(AuthorFormSet(Dict{String,Any}())) == 0                        # test_initial_form_count_empty_data
    for x in collect(objects(MfsAuthor)); delete!(x); end
    # test_edit_only: no new objects
    charles = create(MfsAuthor; name = "Charles Baudelaire")
    EditOnly = modelformset_factory(MfsAuthor; fields = "__all__", edit_only = true)
    formset = EditOnly(Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0",
                            "form-0-name" => "Arthur Rimbaud", "form-1-name" => "Walt Whitman"))
    @test is_valid(formset)
    save!(formset)
    @test [a.id for a in objects(MfsAuthor)] == [charles.id]
    formset = EditOnly(Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0", "form-0-id" => string(charles.id),
                            "form-0-name" => "Arthur Rimbaud", "form-1-name" => "Walt Whitman"))
    @test is_valid(formset)
    save!(formset)
    @test get(MfsAuthor; id = charles.id).name == "Arthur Rimbaud" && [a.id for a in objects(MfsAuthor)] == [charles.id]
    # test_edit_only_inlineformset_factory
    book = create(MfsBook; author = charles, title = "Les Paradis Artificiels")
    formset = inlineformset_factory(MfsAuthor, MfsBook; can_delete = false, fields = "__all__", edit_only = true)(
        Dict("$p-TOTAL_FORMS" => "4", "$p-INITIAL_FORMS" => "1", "$p-MAX_NUM_FORMS" => "0", "$p-0-id" => string(book.id),
             "$p-0-title" => "Les Fleurs du Mal", "$p-0-author" => string(charles.id), "$p-1-title" => "Flowers of Evil", "$p-1-author" => string(charles.id));
        instance = charles)
    @test is_valid(formset)
    save!(formset)
    @test get(MfsBook; id = book.id).title == "Les Fleurs du Mal" && [b.id for b in filter(objects(MfsBook); author = charles)] == [book.id]
    # test_edit_only_object_outside_of_queryset
    walt = create(MfsAuthor; name = "Walt Whitman")
    formset = EditOnly(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-0-id" => string(walt.id), "form-0-name" => "Parth Patil");
                       queryset = filter(objects(MfsAuthor); id = charles.id))
    @test is_valid(formset)
    save!(formset)
    @test get(MfsAuthor; id = walt.id).name == "Walt Whitman" && count(objects(MfsAuthor)) == 2
    # test_edit_only_editable_pk: a forged key in an initial row makes no object
    formset = modelformset_factory(MfsCustomPrimaryKey; fields = "__all__")(
        Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0", "form-0-my_pk" => "forged", "form-0-some_field" => "value"))
    @test is_valid(formset)
    save!(formset)
    @test !exists(filter(objects(MfsCustomPrimaryKey); my_pk = "forged"))
    # (test_edit_only_formset_factory_with_basemodelformset: Django's BaseModelFormSet subclassing)
  end
end

@testset "django model_formsets: TestModelFormsetOverridesTroughFormMeta" begin
  port_block() do
    row(factory; kw...) = Juango.formset_form(factory(); kw...)
    for (factory, name) in ((modelformset_factory(MfsPoet; fields = "__all__", widgets = Dict(:name => Widget(:text; attrs = Dict("class" => "poet")))), :name),
                            (inlineformset_factory(MfsAuthor, MfsBook; widgets = Dict(:title => Widget(:text; attrs = Dict("class" => "book"))), fields = "__all__"), :title))
        cls = name === :name ? "poet" : "book"
        @test html_eq(w(row(factory)[name]), "<input id=\"id_$name\" maxlength=\"100\" type=\"text\" class=\"$cls\" name=\"$name\" required>")
    end
    for factory in (modelformset_factory(MfsBook; fields = "__all__", labels = Dict(:title => "Name")),
                    inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", labels = Dict(:title => "Name")))
        @test html_eq(label_tag(row(factory)[:title]), "<label for=\"id_title\">Name:</label>") && legend_tag(row(factory)[:title]) == "<legend>Name:</legend>"
    end
    for factory in (modelformset_factory(MfsBook; fields = "__all__", help_texts = Dict(:title => "Choose carefully.")),
                    inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", help_texts = Dict(:title => "Choose carefully.")))
        @test row(factory)[:title].field.help_text == "Choose carefully."
    end
    author = create(MfsAuthor; name = "Charles Baudelaire")
    data = Dict("title" => "Foo "^30, "author" => string(author.id))
    for factory in (modelformset_factory(MfsBook; fields = "__all__", error_messages = Dict(:title => Dict("max_length" => "Title too long!!"))),
                    inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", error_messages = Dict(:title => Dict("max_length" => "Title too long!!"))))
        form = row(factory; data)
        @test !is_valid(form) && form.errors[:title] == ["Title too long!!"]
    end
    for factory in (modelformset_factory(MfsBook; fields = "__all__", field_classes = Dict(:title => SlugField)),
                    inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", field_classes = Dict(:title => SlugField)))
        @test Juango.getfield_meta(MfsBook, :title).kind === :char && row(factory; data)[:title].field.kind === :slug
    end
    # absolute_max, with and without max_num
    for (kw, total, nforms, msg) in (((absolute_max = 1500,), 1501, 1500, "Please submit at most 1000 forms."),
                                     ((max_num = 20, absolute_max = 100), 101, 100, "Please submit at most 20 forms."))
        formset = modelformset_factory(MfsAuthor; fields = "__all__", kw...)(Dict("form-TOTAL_FORMS" => string(total), "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0"))
        @test !is_valid(formset) && length(formset.forms) == nforms && non_form_errors(formset) == [msg]
        formset = inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", kw...)(
            Dict("mfsbook_set-TOTAL_FORMS" => string(total), "mfsbook_set-INITIAL_FORMS" => "0", "mfsbook_set-MAX_NUM_FORMS" => "0"); instance = author)
        @test !is_valid(formset) && length(formset.forms) == nforms && non_form_errors(formset) == [msg]
    end
    # can_delete_extra
    for (extra_delete, has) in ((true, true), (false, false))
        for formset in (modelformset_factory(MfsAuthor; fields = "__all__", can_delete = true, can_delete_extra = extra_delete, extra = 2)(; queryset = none(MfsAuthor)),
                        inlineformset_factory(MfsAuthor, MfsBook; fields = "__all__", can_delete = true, can_delete_extra = extra_delete, extra = 2)())
            @test length(formset) == 2 && all(f -> (:DELETE in mf_names(f)) == has, formset.forms)
        end
    end
    # (test_*_passes_renderer, test_*_default_renderer: Django's renderers)
  end
end

# --- tests/inline_formsets/models.py --------------------------------------------------------------------
@model struct IfsSchool
    name = CharField(max_length = 100)
    Meta(table = "ifs_school")
end
@model struct IfsParent
    name = CharField(max_length = 100)
    Meta(table = "ifs_parent")
end
@model struct IfsChild
    mother = ForeignKey(IfsParent, on_delete = :CASCADE, related_name = :mothers_children)
    father = ForeignKey(IfsParent, on_delete = :CASCADE, related_name = :fathers_children)
    school = ForeignKey(IfsSchool, on_delete = :CASCADE)
    name = CharField(max_length = 100)
    Meta(table = "ifs_child", constraints = [UniqueConstraint(F(:mother), F(:father); name = "ifs_unique_parents")])     # (expressions, as Django's)
end
@model struct IfsPoet
    name = CharField(max_length = 100)
    Meta(table = "ifs_poet")
end
@model struct IfsPoem
    poet = ForeignKey(IfsPoet, on_delete = :CASCADE)
    name = CharField(max_length = 100)
    Meta(table = "ifs_poem", unique_together = [(:poet, :name)])
end
redirect_stdout(devnull) do
    ms = [IfsSchool, IfsParent, IfsChild, IfsPoet, IfsPoem]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django inline_formsets: DeletionTests" begin
  port_block() do
    PoemFormSet = inlineformset_factory(IfsPoet, IfsPoem; can_delete = true, fields = "__all__")
    p = "ifspoem_set"
    # test_deletion
    poet = create(IfsPoet; name = "test")
    poem = create(IfsPoem; poet, name = "test poem")
    formset = PoemFormSet(Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "1", "$p-MAX_NUM_FORMS" => "0", "$p-0-id" => string(poem.id),
                               "$p-0-poet" => string(poet.id), "$p-0-name" => "test", "$p-0-DELETE" => "on"); instance = poet)
    save!(formset)
    @test is_valid(formset) && count(objects(IfsPoem)) == 0
    # test_add_form_deletion_when_invalid
    data = Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "0", "$p-0-id" => "", "$p-0-poem" => "1", "$p-0-name" => "x"^1000)
    @test !is_valid(PoemFormSet(data; instance = poet)) && count(objects(IfsPoem)) == 0
    data["$p-0-DELETE"] = "on"
    formset = PoemFormSet(data; instance = poet)
    @test is_valid(formset)
    save!(formset)
    @test count(objects(IfsPoem)) == 0
    # test_change_form_deletion_when_invalid
    poem = create(IfsPoem; poet, name = "test poem")
    data = Dict("$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "1", "$p-MAX_NUM_FORMS" => "0", "$p-0-id" => string(poem.id),
                "$p-0-poem" => string(poem.id), "$p-0-name" => "x"^1000)
    @test !is_valid(PoemFormSet(data; instance = poet)) && count(objects(IfsPoem)) == 1
    data["$p-0-DELETE"] = "on"
    formset = PoemFormSet(data; instance = poet)
    @test is_valid(formset)
    save!(formset)
    @test count(objects(IfsPoem)) == 0
    # test_save_new (#10750): save!(commit = false), the required fields left out of the form set by hand
    ChildFormSet = inlineformset_factory(IfsSchool, IfsChild; exclude = [:father, :mother])
    school = create(IfsSchool; name = "test")
    mother, father = create(IfsParent; name = "mother"), create(IfsParent; name = "father")
    formset = ChildFormSet(Dict("ifschild_set-TOTAL_FORMS" => "1", "ifschild_set-INITIAL_FORMS" => "0", "ifschild_set-MAX_NUM_FORMS" => "0",
                                "ifschild_set-0-name" => "child"); instance = school)
    @test is_valid(formset)
    for obj in save!(formset; commit = false)
        obj.mother, obj.father = mother, father
        save!(obj)
    end
    @test count(filter(objects(IfsChild); school)) == 1
    # (test_add_form_uuid_pk: a database-generated UUID key)
  end
end

@testset "django inline_formsets: InlineFormsetFactoryTest, constraints" begin
  port_block() do
    # test_inline_formset_factory, test_any_iterable_allowed_as_argument_to_exclude (#9171)
    @test inlineformset_factory(IfsParent, IfsChild; fk = :mother, fields = "__all__") isa Function
    @test inlineformset_factory(IfsParent, IfsChild; fk = :father, fields = "__all__") isa Function
    @test inlineformset_factory(IfsParent, IfsChild; exclude = [:school], fk = :mother) isa Function
    @test inlineformset_factory(IfsParent, IfsChild; exclude = (:school,), fk = :mother) isa Function
    msg(f) = try f(); "" catch e; e isa ArgumentError ? e.msg : rethrow() end
    @test startswith(msg(() -> inlineformset_factory(IfsParent, IfsChild)), "'IfsChild' has more than one ForeignKey to 'IfsParent'.")
    @test msg(() -> inlineformset_factory(IfsParent, IfsChild; fk = :school)) == "fk_name 'school' is not a ForeignKey to 'IfsParent'."
    @test msg(() -> inlineformset_factory(IfsParent, IfsChild; fk = :test)) == "'IfsChild' has no field named 'test'."
    # (test_zero_primary_key: an automatic key of 0)
    # test_unsaved_fk_validate_unique: rows of an unsaved parent still mustn't repeat each other
    PoemFormSet = inlineformset_factory(IfsPoet, IfsPoem; fields = [:name])
    p = "ifspoem_set"
    formset = PoemFormSet(Dict("$p-TOTAL_FORMS" => "2", "$p-INITIAL_FORMS" => "0", "$p-MAX_NUM_FORMS" => "2", "$p-0-name" => "Poem", "$p-1-name" => "Poem");
                          instance = IfsPoet(name = "unsaved"))
    @test (is_valid(formset), non_form_errors(formset), Juango.errors(formset)) == (false, ["Please correct the duplicate data for name."], [Dict(), Dict(:__all__ => ["Please correct the duplicate values below."])])
    # test_fk_not_duplicated_in_form_fields (#21332), test_fk_in_all_formset_forms (#26538)
    poet = create(IfsPoet; name = "test")
    for n in ("first", "second", "third"); create(IfsPoem; poet, name = "$n test poem"); end
    formset = inlineformset_factory(IfsPoet, IfsPoem; fields = (:name,), extra = 0)(; instance = poet)
    @test length(formset.forms) == 3 && all(f -> count(x -> x.name === :poet, f.fields) == 1 && count(x -> x.name === :name, f.fields) == 1, formset.forms)
    # test_constraint_refs_inline_foreignkey_field (#35676): a constraint on the parent's key is checked
    ChildFormSet = inlineformset_factory(IfsParent, IfsChild; fk = :mother, fields = "__all__", extra = 1)
    father, school, mother = create(IfsParent; name = "James"), create(IfsSchool; name = "Hogwarts"), create(IfsParent; name = "Lily")
    create(IfsChild; name = "Harry", father, mother, school)
    formset = ChildFormSet(Dict("mothers_children-TOTAL_FORMS" => "1", "mothers_children-INITIAL_FORMS" => "0", "mothers_children-MIN_NUM_FORMS" => "0",
                                "mothers_children-MAX_NUM_FORMS" => "1000", "mothers_children-0-id" => "", "mothers_children-0-father" => string(father.id),
                                "mothers_children-0-school" => string(school.id), "mothers_children-0-name" => "Mary"); instance = mother)
    @test (is_valid(formset), Juango.errors(formset)) == (false, [Dict(:__all__ => ["Constraint “ifs_unique_parents” is violated."])])
  end
end
