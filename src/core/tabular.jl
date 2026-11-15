# Reading tables: CSV and XLSX (the other half of xlsx.jl) ------------------------------------------------
#
#     parse_csv(read("people.csv", String))      # rows of strings
#     read_xlsx(read("people.xlsx"))              # rows of the first sheet: strings, numbers, booleans, nothing
#
# Enough for imports from spreadsheets (Excel, LibreOffice, Google Sheets exports); for anything
# more (formulas, several sheets, styles), use XLSX.jl.

"""
    parse_csv(text; delimiter = ',', unprotect = true) -> Vector{Vector{String}}

The rows of a CSV text (RFC 4180: fields in double quotes may hold the delimiter, quotes doubled,
and line breaks; a byte-order mark is skipped; blank lines are dropped). With `unprotect`, a field
starting with `'` followed by `=`, `+`, `-` or `@` loses the `'` that Juango's CSV exports add
against formula injection (`csv_field`), so an export imports back unchanged.
"""
function parse_csv(text::AbstractString; delimiter::Char = ',', unprotect::Bool = true)
    s = String(text)
    startswith(s, '﻿') && (s = s[nextind(s, 1):end])
    rows = Vector{Vector{String}}()
    row, field = String[], IOBuffer()
    inq, quoted, i, n = false, false, firstindex(s), lastindex(s)
    endfield() = (v = String(take!(field)); push!(row, unprotect && !quoted && occursin(r"^'[=+\-@]", v) ? v[2:end] : v); quoted = false)
    endrow() = (all(isempty, row) && length(row) <= 1 || push!(rows, row); row = String[])
    while i <= n
        c = s[i]
        if inq
            if c == '"'
                j = nextind(s, i)
                if j <= n && s[j] == '"'
                    write(field, '"'); i = j
                else
                    inq = false
                end
            else
                write(field, c)
            end
        elseif c == '"'
            inq = quoted = true
        elseif c == delimiter
            endfield()
        elseif c == '\r' || c == '\n'
            endfield(); endrow()
            c == '\r' && (j = nextind(s, i); j <= n && s[j] == '\n') && (i = j)
        else
            write(field, c)
        end
        i = nextind(s, i)
    end
    (position(field) > 0 || !isempty(row)) && (endfield(); endrow())
    rows
end

# --- XLSX: unzip, then the shared strings and the first worksheet ---

"The entries of a zip archive, name => bytes (stored or deflated)."
function unzip_entries(data::Vector{UInt8})
    le16(i) = UInt16(data[i]) | UInt16(data[i+1]) << 8
    le32(i) = UInt32(le16(i)) | UInt32(le16(i + 2)) << 16
    eocd = findlast(i -> data[i] == 0x50 && data[i+1] == 0x4b && data[i+2] == 0x05 && data[i+3] == 0x06, 1:length(data)-21)
    eocd === nothing && throw(ArgumentError("not a zip file (no end of central directory)"))
    count_, cd = Int(le16(eocd + 10)), Int(le32(eocd + 16)) + 1
    out = Dict{String,Vector{UInt8}}()
    p = cd
    for _ in 1:count_
        le32(p) == 0x02014b50 || throw(ArgumentError("a damaged zip central directory"))
        method, csize = le16(p + 10), Int(le32(p + 20))
        nlen, xlen, clen = Int(le16(p + 28)), Int(le16(p + 30)), Int(le16(p + 32))
        local_ = Int(le32(p + 42)) + 1
        name = String(data[p+46:p+45+nlen])
        le32(local_) == 0x04034b50 || throw(ArgumentError("a damaged zip entry: $name"))
        start = local_ + 30 + Int(le16(local_ + 26)) + Int(le16(local_ + 28))
        raw = data[start:start+csize-1]
        out[name] = method == 0 ? raw : method == 8 ? transcode(CodecZlib.DeflateDecompressor, raw) :
                    throw(ArgumentError("zip entry $name uses compression method $method"))
        p += 46 + nlen + xlen + clen
    end
    out
end

xml_unescape(s) = replace(s, "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&apos;" => "'", r"&#(\d+);" => m -> string(Char(parse(Int, m[3:end-1]))),
                          r"&#x([0-9a-fA-F]+);" => m -> string(Char(parse(Int, m[4:end-1]; base = 16))), "&amp;" => "&")
"The text of the `<t>` runs inside an XML fragment (a shared string or an inline string)."
xml_text_runs(frag) = join(xml_unescape(m[1]) for m in eachmatch(r"<t(?:\s[^>]*)?>(.*?)</t>"s, frag))
"A cell reference's column number: `\"C7\"` → 3."
column_number(ref) = foldl((n, c) -> 26n + (c - 'A' + 1), (c for c in uppercase(ref) if isletter(c)); init = 0)

"""
    read_xlsx(data::Vector{UInt8}; sheet = 1) -> Vector{Vector{Any}}

The rows of a worksheet (the first, or `sheet` by number or name) of an XLSX file: strings,
numbers (Int when whole), booleans and `nothing` for empty cells, padded to the widest row. Dates
are numbers (Excel serials) as the file stores them; `excel_date` converts one.
"""
function read_xlsx(data::Vector{UInt8}; sheet = 1)
    z = unzip_entries(data)
    rd(name) = haskey(z, name) ? String(z[name]) : ""
    shared = [xml_text_runs(m[1]) for m in eachmatch(r"<si>(.*?)</si>"s, rd("xl/sharedStrings.xml"))]
    # the sheet's file, through the workbook and its relationships
    wb = rd("xl/workbook.xml")
    sheets = [(xml_unescape(m[1]), m[2]) for m in eachmatch(r"<sheet\b[^>]*\bname=\"([^\"]*)\"[^>]*\br:id=\"([^\"]+)\""s, wb)]
    isempty(sheets) && throw(ArgumentError("the workbook has no sheets"))
    pick = if sheet isa Integer
        1 <= sheet <= length(sheets) || throw(ArgumentError("no sheet $sheet (the workbook has $(length(sheets)))"))
        sheets[sheet]
    else
        i = findfirst(s -> s[1] == string(sheet), sheets)
        i === nothing && throw(ArgumentError("no sheet named $(repr(sheet))"))
        sheets[i]
    end
    rels = rd("xl/_rels/workbook.xml.rels")
    m = match(Regex("<Relationship\\b[^>]*\\bId=\"$(pick[2])\"[^>]*\\bTarget=\"([^\"]+)\""), rels)
    m === nothing && (m = match(Regex("<Relationship\\b[^>]*\\bTarget=\"([^\"]+)\"[^>]*\\bId=\"$(pick[2])\""), rels))
    target = m === nothing ? "worksheets/sheet1.xml" : m[1]
    path = startswith(target, "/") ? target[2:end] : "xl/" * target
    xml = rd(path)
    isempty(xml) && throw(ArgumentError("the worksheet $path is missing"))
    rows = Vector{Vector{Any}}()
    for rm in eachmatch(r"<row\b[^>]*?(?:/>|>(.*?)</row>)"s, xml)
        cells = Dict{Int,Any}()
        rm[1] === nothing || for cm in eachmatch(r"<c\b([^>]*?)(?:/>|>(.*?)</c>)"s, rm[1])
            attrs, body = cm[1], something(cm[2], "")
            ref = match(r"\br=\"([A-Z]+)\d*\"", attrs)
            col = ref === nothing ? length(cells) + 1 : column_number(ref[1])
            t = match(r"\bt=\"([^\"]+)\"", attrs)
            t = t === nothing ? "n" : t[1]
            v = match(r"<v>(.*?)</v>"s, body)
            val = if t == "s"
                v === nothing ? nothing : shared[parse(Int, v[1])+1]
            elseif t == "inlineStr"
                xml_text_runs(body)
            elseif t == "b"
                v === nothing ? nothing : v[1] == "1"
            elseif t in ("str", "e")
                v === nothing ? nothing : xml_unescape(v[1])
            else
                v === nothing ? nothing : (x = parse(Float64, v[1]); isinteger(x) && abs(x) < 2^53 ? Int(x) : x)
            end
            cells[col] = val
        end
        width = isempty(cells) ? 0 : maximum(keys(cells))
        push!(rows, Any[get(cells, j, nothing) for j in 1:width])
    end
    while !isempty(rows) && all(isnothing, rows[end])      # trailing empty rows
        pop!(rows)
    end
    w = isempty(rows) ? 0 : maximum(length, rows)
    foreach(r -> append!(r, fill(nothing, w - length(r))), rows)
    rows
end

"An Excel date serial (a cell of a date column) as a Date, or a DateTime when it has a time of day."
function excel_date(x::Real)
    d = Date(1899, 12, 30) + Day(floor(Int, x))
    f = x - floor(x)
    f == 0 ? d : DateTime(d) + Millisecond(round(Int, f * 86_400_000))
end
