local t = thor.theme

-- Slang (the GPU shading language) pure-Lua lexer. C-like, so only /* */ carries
-- across the line loop. Beyond the C shape it colours the Slang/HLSL builtin
-- types (including the float3 / half4x4 vector and matrix forms), `[shader(...)]`
-- attributes and the `: SV_Position` semantics.
local KEYWORDS = {}
for _, w in ipairs {
    "if", "else", "switch", "case", "default", "for", "while", "do", "break",
    "continue", "return", "discard", "defer", "try", "throw", "throws",
    "struct", "class", "interface", "extension", "enum", "namespace", "typedef",
    "typealias", "associatedtype", "where", "func", "var", "let", "property",
    "this", "This", "new", "operator", "init", "subscript", "get", "set",
    "import", "module", "implementing", "cbuffer", "tbuffer", "register",
    "packoffset", "sizeof", "alignof", "countof",
    "const", "static", "uniform", "in", "out", "inout", "ref", "groupshared",
    "shared", "globallycoherent", "precise", "nointerpolation", "noperspective",
    "linear", "centroid", "sample", "column_major", "row_major", "volatile",
    "extern", "export", "public", "private", "internal", "inline", "no_diff",
    "dynamic_uniform", "spirv_asm", "each", "expand",
    "__generic", "__init", "__subscript", "__include", "__exported",
    "__intrinsic_asm", "__target_switch", "__extension",
} do
    KEYWORDS[w] = true
end

local CONSTANTS = {}
for _, w in ipairs { "true", "false", "null", "nullptr", "none" } do
    CONSTANTS[w] = true
end

local TYPES = {}
for _, w in ipairs {
    "void", "bool", "int", "uint", "half", "float", "double", "vector", "matrix",
    "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t",
    "uint32_t", "uint64_t", "float16_t", "float32_t", "float64_t",
    "intptr_t", "uintptr_t",
    "Texture1D", "Texture1DArray", "Texture2D", "Texture2DArray", "Texture2DMS",
    "Texture2DMSArray", "Texture3D", "TextureCube", "TextureCubeArray",
    "RWTexture1D", "RWTexture1DArray", "RWTexture2D", "RWTexture2DArray",
    "RWTexture3D", "RasterizerOrderedTexture2D", "SamplerState",
    "SamplerComparisonState", "Buffer", "RWBuffer", "TextureBuffer",
    "StructuredBuffer", "RWStructuredBuffer", "AppendStructuredBuffer",
    "ConsumeStructuredBuffer", "RasterizerOrderedStructuredBuffer",
    "ByteAddressBuffer", "RWByteAddressBuffer", "ConstantBuffer",
    "ParameterBlock", "RaytracingAccelerationStructure", "RayDesc", "RayQuery",
    "BuiltInTriangleIntersectionAttributes",
    "PointStream", "LineStream", "TriangleStream", "InputPatch", "OutputPatch",
    "Array", "Optional", "Ptr", "String", "NativeString", "Tuple", "DiffPair",
    "Atomic", "IFloat", "IArithmetic", "IComparable", "IDifferentiable",
} do
    TYPES[w] = true
end

-- Scalars that take a vector (float3) or matrix (float4x4) suffix.
local VECTOR_BASE = {}
for _, w in ipairs { "bool", "int", "uint", "half", "float", "double" } do
    VECTOR_BASE[w] = true
end

-- Declarations whose following name is the declared type.
local DECLARES_TYPE = {}
for _, w in ipairs { "struct", "class", "interface", "enum", "extension", "typealias" } do
    DECLARES_TYPE[w] = true
end

local function is_type(w)
    if TYPES[w] then
        return true
    end
    local base = w:match("^(%a+)[1-4]$") or w:match("^(%a+)[1-4]x[1-4]$")
    return base ~= nil and VECTOR_BASE[base] == true
end

-- Index (1-based, inclusive) of the closing quote of a double-quoted string that
-- opens at `p`, honoring backslash escapes; nil when unterminated.
local function dquote_end(line, p)
    local i = p + 1
    local len = #line
    while i <= len do
        local c = line:sub(i, i)
        if c == "\\" then
            i = i + 2
        elseif c == '"' then
            return i
        else
            i = i + 1
        end
    end
    return nil
end

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local in_comment = false

    local function inline(line, base, p)
        local len = #line
        -- #include <path>: the angle form is a string only on such a line.
        local include_line = line:match("^%s*#%s*include") ~= nil

        while p <= len do
            if in_comment then
                local e = line:find("*/", p, true)
                if e then
                    push(base + p - 1, base + e + 1, t.comments)
                    in_comment = false
                    p = e + 2
                else
                    push(base + p - 1, base + len, t.comments)
                    return
                end
                goto continue
            end

            local c = line:sub(p, p)
            local two = line:sub(p, p + 1)
            local s, e

            -- // line comment
            if two == "//" then
                push(base + p - 1, base + len, t.comments)
                return
            end
            -- /* block comment (may run onto later lines)
            if two == "/*" then
                in_comment = true
                goto continue
            end
            -- preprocessor directive, only with nothing but space before it
            if c == "#" and line:sub(1, p - 1):match("^%s*$") then
                s, e = line:find("^#%s*[%a_]+", p)
                if s then push(base + s - 1, base + e, t.orange); p = e + 1; goto continue end
            end
            -- <path> of an #include
            if include_line and c == "<" then
                s, e = line:find("^<[^>]*>", p)
                if s then push(base + s - 1, base + e, t.strings); p = e + 1; goto continue end
            end
            -- string, honoring backslash escapes
            if c == '"' then
                local q = dquote_end(line, p)
                local last = q or len
                push(base + p - 1, base + last, t.strings)
                p = last + 1
                goto continue
            end
            -- character literal
            s, e = line:find("^'\\?[^']'", p)
            if s then push(base + s - 1, base + e, t.orange); p = e + 1; goto continue end
            -- [shader("vertex")] / [[vk::binding(0)]]: the name only, so the
            -- arguments still lex. An attribute opens a line or follows another.
            if c == "[" then
                local before = line:sub(1, p - 1)
                if before:match("^%s*$") or before:match("%]%s*$") then
                    local _, bracket = line:find("^%[%[?%s*", p)
                    local ns, ne = line:find("^[%a_][%w_]*", bracket + 1)
                    if ns then
                        local _, qe = line:find("^::[%a_][%w_]*", ne + 1)
                        if qe then ne = qe end
                        push(base + ns - 1, base + ne, t.attributes)
                        p = ne + 1
                        goto continue
                    end
                end
            end
            -- `: SV_Position` / `: TEXCOORD0` semantic, not the `::` qualifier
            if c == ":" and line:sub(p + 1, p + 1) ~= ":" and line:sub(p - 1, p - 1) ~= ":" then
                local _, se, name = line:find("^:%s*([%a_][%w_]*)", p)
                if name and (name:match("^SV_") or name:match("^%u[%u%d_]+$")) then
                    push(base + se - #name, base + se, t.attributes)
                    p = se + 1
                    goto continue
                end
            end
            -- number: hex, exponent, fractional, then plain, each with suffixes
            s, e = line:find("^0[xX]%x+[uUlL]*", p)
            if not s then s, e = line:find("^%d+%.?%d*[eE][-+]?%d+[fFhH]?", p) end
            if not s then s, e = line:find("^%d*%.%d+[fFhH]?", p) end
            if not s then s, e = line:find("^%d+%.[fFhH]?", p) end
            if not s then s, e = line:find("^%d+[uUlLfFhH]*", p) end
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- word: keyword, constant, builtin or declared type, or a call
            s, e = line:find("^[%a_][%w_]*", p)
            if s then
                local w = line:sub(s, e)
                local before = line:sub(1, s - 1)
                local prev = before:match("([%a_][%w_]*)%s+$")
                if KEYWORDS[w] then
                    push(base + s - 1, base + e, t.keywords)
                elseif CONSTANTS[w] then
                    push(base + s - 1, base + e, t.orange)
                elseif is_type(w) or (prev ~= nil and DECLARES_TYPE[prev]) then
                    push(base + s - 1, base + e, t.yellow)
                elseif line:sub(e + 1):match("^%s*%(") then
                    push(base + s - 1, base + e, t.functions)
                end
                p = e + 1
                goto continue
            end

            if c:match("[%+%-%*/%%=<>!&|%^~%?:;,%.]") then
                push(base + p - 1, base + p, t.operators)
            end
            p = p + 1
            ::continue::
        end
    end

    local i = 1
    local n = #src
    while i <= n do
        local nl = src:find("\n", i, true)
        local stop = nl and (nl - 1) or n
        local line = src:sub(i, stop)
        local base = i - 1
        i = (nl or n) + 1

        inline(line, base, 1)
    end

    return spans
end

thor.register_language {
    name       = "Slang",
    extensions = { ".slang", ".slangh" },
    highlight  = lex,
}
