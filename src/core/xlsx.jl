# A small XLSX writer: one sheet of values -------------------------------------------------------------------
#
#     write_xlsx("report.xlsx", [["Name", "Born"], ["Ann", Date(1990, 5, 1)]])
#     XlsxResponse(rows; filename = "report.xlsx")              # a download from a view
#
# Numbers, booleans, dates and datetimes (as real Excel dates), and text; `nothing` is an empty
# cell. The first row is bold with `header = true` (the default). Enough for exports that open
# in Excel, LibreOffice and Google Sheets; for reading or formatting workbooks, use XLSX.jl.

# --- zip (stored, no compression: valid in every reader, and spreadsheets of text are small) ---------

# (crc32 is http/httpcache.jl's, used for gzip too)

"A zip archive of `(name, bytes)` entries, stored (not compressed)."
function zip_bytes(entries)
    io = IOBuffer()
    central = IOBuffer()
    le(x) = write(io, htol(x))
    for (name, data) in entries
        name_b = Vector{UInt8}(codeunits(name))
        offset = position(io)
        crc = crc32(data)
        # local file header
        le(0x04034b50); le(UInt16(20)); le(UInt16(0x0800)); le(UInt16(0)); le(UInt16(0)); le(UInt16(0x21))
        le(crc); le(UInt32(length(data))); le(UInt32(length(data))); le(UInt16(length(name_b))); le(UInt16(0))
        write(io, name_b); write(io, data)
        # its central directory record
        c(x) = write(central, htol(x))
        c(0x02014b50); c(UInt16(20)); c(UInt16(20)); c(UInt16(0x0800)); c(UInt16(0)); c(UInt16(0)); c(UInt16(0x21))
        c(crc); c(UInt32(length(data))); c(UInt32(length(data))); c(UInt16(length(name_b))); c(UInt16(0)); c(UInt16(0))
        c(UInt16(0)); c(UInt16(0)); c(UInt32(0)); c(UInt32(offset)); write(central, name_b)
    end
    cd_offset = position(io)
    cd = take!(central)
    write(io, cd)
    le(0x06054b50); le(UInt16(0)); le(UInt16(0)); le(UInt16(length(entries))); le(UInt16(length(entries)))
    le(UInt32(length(cd))); le(UInt32(cd_offset)); le(UInt16(0))
    take!(io)
end

# --- the workbook ---------------------------------------------------------------------------------

xml_text(s) = escape_html(replace(string(s), r"[\x00-\x08\x0B\x0C\x0E-\x1F]" => ""))     # XML can't hold control characters
function column_letters(n::Int)
    s = ""
    while n > 0
        n, r = divrem(n - 1, 26)
        s = string(Char('A' + r)) * s
    end
    s
end
excel_serial(d::Date) = Dates.value(d - Date(1899, 12, 30))
excel_serial(d::DateTime) = Dates.value(Date(d) - Date(1899, 12, 30)) + Dates.value(d - DateTime(Date(d))) / 86_400_000

function xlsx_cell(io::IO, ref::String, @nospecialize(v), header::Bool)
    v === nothing && return
    v isa TimeZones.ZonedDateTime && (v = DateTime(localtime(v)))
    if v isa Bool
        print(io, "<c r=\"", ref, "\" t=\"b\"><v>", v ? 1 : 0, "</v></c>")
    elseif v isa Union{Integer,AbstractFloat,Decimal} && !header
        x = v isa AbstractFloat && !isfinite(v) ? nothing : string(v)
        x === nothing ? print(io, "<c r=\"", ref, "\" t=\"inlineStr\"><is><t>", v, "</t></is></c>") :
                        print(io, "<c r=\"", ref, "\"><v>", x, "</v></c>")
    elseif v isa DateTime && !header
        print(io, "<c r=\"", ref, "\" s=\"2\"><v>", excel_serial(v), "</v></c>")
    elseif v isa Date && !header
        print(io, "<c r=\"", ref, "\" s=\"1\"><v>", excel_serial(v), "</v></c>")
    else
        print(io, "<c r=\"", ref, "\" t=\"inlineStr\"", header ? " s=\"3\"" : "", "><is><t xml:space=\"preserve\">",
              xml_text(v isa SafeString ? v.s : display_string(v)), "</t></is></c>")
    end
end

const XLSX_STYLES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>"""

"""
    xlsx_bytes(rows; header = true, sheet = "Sheet1") -> Vector{UInt8}

An XLSX workbook of one sheet holding `rows` (each a vector of values), as bytes.
"""
function xlsx_bytes(rows; header::Bool = true, sheet::AbstractString = "Sheet1")
    sh = IOBuffer()
    print(sh, """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>""")
    for (i, row) in enumerate(rows)
        print(sh, "<row r=\"", i, "\">")
        for (j, v) in enumerate(row)
            xlsx_cell(sh, column_letters(j) * string(i), v, header && i == 1)
        end
        print(sh, "</row>")
    end
    print(sh, "</sheetData></worksheet>")
    b(s) = Vector{UInt8}(codeunits(s))
    zip_bytes([
        "[Content_Types].xml" => b("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"""),
        "_rels/.rels" => b("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"""),
        "xl/workbook.xml" => b("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="$(xml_text(first(sheet, 31)))" sheetId="1" r:id="rId1"/></sheets></workbook>"""),
        "xl/_rels/workbook.xml.rels" => b("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"""),
        "xl/styles.xml" => b(XLSX_STYLES),
        "xl/worksheets/sheet1.xml" => take!(sh),
    ])
end

"Write `rows` to an XLSX file (or IO): see `xlsx_bytes`."
write_xlsx(path::AbstractString, rows; kw...) = write(path, xlsx_bytes(rows; kw...))
write_xlsx(io::IO, rows; kw...) = write(io, xlsx_bytes(rows; kw...))

"""
    XlsxResponse(rows; filename = "data.xlsx", header = true, sheet = "Sheet1")

An XLSX download of `rows` (each a vector of values; the first row a bold header).
"""
function XlsxResponse(rows; filename = "data.xlsx", kw...)
    r = HttpResponse(xlsx_bytes(rows; kw...); content_type = MIME_TYPES[".xlsx"])
    setheader!(r, "Content-Disposition", content_disposition(string(filename); attachment = true))
    r
end
