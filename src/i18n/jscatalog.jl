# JavaScript translations --------------------------------------------------------------------------------
#
#     path("jsi18n/", JavaScriptCatalog())
#     <script src="{% url 'jsi18n' %}"></script>
#     <script>alert(interpolate(ngettext("%s item", "%s items", n), [n]))</script>
#
# The script defines gettext, ngettext, pgettext, npgettext, gettext_noop, interpolate,
# pluralidx and get_format (also under `juango.`), with the active language's translations.

"The translations of the active language as JavaScript-ready data: msgid (or `context\\x04msgid`) => string or plural forms."
function js_catalog_data(; prefixes = nothing)
    c = catalog(get_language())
    out = Dict{String,Any}()
    for ((ctx, id), strs) in c.messages
        prefixes === nothing || any(p -> startswith(id, p), prefixes) || continue
        out[(isempty(ctx) ? "" : ctx * "\x04") * id] = length(strs) == 1 ? strs[1] : strs
    end
    out, c.plural_expr
end

js_formats() = (f = get_format(); Dict("DATE_FORMAT" => f.date, "DATETIME_FORMAT" => f.datetime,
                                         "DECIMAL_SEPARATOR" => decimal_separator(), "THOUSAND_SEPARATOR" => thousand_separator()))

const JS_CATALOG_TEMPLATE = raw"""
(function (globals) {
  "use strict";
  const juango = globals.juango || (globals.juango = {});
  juango.pluralidx = function (n) {
    const v = (__PLURAL__);
    return typeof v === "boolean" ? (v ? 1 : 0) : v;
  };
  juango.catalog = __CATALOG__;
  juango.formats = __FORMATS__;
  juango.gettext = function (msgid) {
    const value = juango.catalog[msgid];
    if (typeof value === "undefined") return msgid;
    return typeof value === "string" ? value : value[0];
  };
  juango.ngettext = function (singular, plural, count) {
    const value = juango.catalog[singular];
    if (typeof value === "undefined") return count == 1 ? singular : plural;
    return value.constructor === Array ? value[juango.pluralidx(count)] : value;
  };
  juango.gettext_noop = function (msgid) { return msgid; };
  juango.pgettext = function (context, msgid) {
    const value = juango.gettext(context + "\x04" + msgid);
    return value.includes("\x04") ? msgid : value;
  };
  juango.npgettext = function (context, singular, plural, count) {
    const value = juango.ngettext(context + "\x04" + singular, context + "\x04" + plural, count);
    return value.includes("\x04") ? juango.ngettext(singular, plural, count) : value;
  };
  juango.interpolate = function (fmt, obj, named) {
    if (named) return fmt.replace(/%\(\w+\)s/g, function (m) { return String(obj[m.slice(2, -2)]); });
    return fmt.replace(/%s/g, function () { return String(obj.shift()); });
  };
  juango.get_format = function (name) {
    const value = juango.formats[name];
    return typeof value === "undefined" ? name : value;
  };
  for (const k of ["pluralidx", "gettext", "ngettext", "gettext_noop", "pgettext", "npgettext", "interpolate", "get_format"])
    globals[k] = juango[k];
}(this));
"""

"""
    JavaScriptCatalog(; prefixes = nothing)

A view serving the active language's translations as JavaScript (see jscatalog.jl).
`prefixes` limits it to msgids starting with one of them, to keep the script small.
"""
function JavaScriptCatalog(; prefixes = nothing)
    name_view!(function (req::Request; kw...)
        data, expr = js_catalog_data(; prefixes = prefixes)
        safe_expr = occursin(r"^[n0-9\s()!=<>&|?:%+\-*/]+$", expr) ? expr : "n != 1"
        js = replace(JS_CATALOG_TEMPLATE, "__PLURAL__" => safe_expr, "__CATALOG__" => JSON.json(data),
                     "__FORMATS__" => JSON.json(js_formats()))
        HttpResponse(js; content_type = "text/javascript; charset=utf-8")
    end, "JavaScriptCatalog")
end

"""
    JSONCatalog(; prefixes = nothing)

The same translations as JSON: `{"catalog": {...}, "formats": {...}, "plural": "n != 1"}`.
"""
function JSONCatalog(; prefixes = nothing)
    name_view!(function (req::Request; kw...)
        data, expr = js_catalog_data(; prefixes = prefixes)
        JsonResponse(Dict("catalog" => data, "formats" => js_formats(), "plural" => expr))
    end, "JSONCatalog")
end
