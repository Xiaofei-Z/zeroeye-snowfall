-- =============================================================================
-- openapi_diff.lua  -  OpenAPI Spec Diff Tool with Breaking-Change Classification
-- =============================================================================

local DIFF_COLOR_ADD    = "\27[32m"
local DIFF_COLOR_REMOVE = "\27[31m"
local DIFF_COLOR_CHANGE = "\27[33m"
local DIFF_COLOR_META   = "\27[36m"
local DIFF_COLOR_BREAK  = "\27[31;1m"
local DIFF_COLOR_RESET  = "\27[0m"

-- =============================================================================
-- YAML Keyword Parser
-- =============================================================================

local function parse_yaml_keywords(filepath)
  local file, err = io.open(filepath, "r")
  if not file then
    io.stderr:write("[Diff] Cannot open file: " .. filepath .. "\n")
    os.exit(1)
  end
  local content = file:read("*all")
  file:close()

  local paths = {}
  local methods = {}
  local schemas = {}
  local fields = {}
  local enums = {}
  local responses = {}
  local emoji_count = 0

  local current_path = nil
  local current_schema = nil
  local in_enum = false
  local in_schemas = false

  for line in content:gmatch("[^\r\n]+") do
    local indent = line:match("^(%s*)")
    local indent_level = indent and #indent or 0

    -- Check for YAML list item (e.g. "  - admin")
    local list_val = line:match("^%s-%-%s+(.+)")
    if list_val then
      local trimmed = list_val:gsub('"', ""):gsub("^%s+", ""):gsub("%s+$", "")
      if in_enum and current_schema then
        table.insert(enums[current_schema], trimmed)
      end
      goto continue
    end

    local key, value = line:match("^%s*([^:]+):%s*(.*)")
    if key then
      key = key:gsub("^%s+", ""):gsub("%s+$", "")
      value = value or ""

      -- Detect path definitions (indent level 2, starts with /)
      if indent_level == 2 and key:match("^/") then
        current_path = key
        table.insert(paths, { path = key })
        methods[current_path] = methods[current_path] or {}
        responses[current_path] = responses[current_path] or {}
        in_enum = false
      end

      -- Detect HTTP methods under paths
      if indent_level == 4 and (key == "get" or key == "post" or key == "put"
          or key == "delete" or key == "patch" or key == "head" or key == "options") then
        if current_path then
          table.insert(methods[current_path], key)
        end
        in_enum = false
      end

      -- Detect response codes
      if indent_level == 6 and key:match("^%d") then
        if current_path then
          table.insert(responses[current_path], key)
        end
        in_enum = false
      end

      -- Track components/schemas context
      if indent_level == 0 and key == "components" then
        in_schemas = true
      elseif indent_level == 0 and key ~= "components" then
        in_schemas = false
      end

      -- Detect schema definitions (within components/schemas, indent 4)
      if in_schemas and indent_level == 4 and key:match("^[%w_]+$") then
        current_schema = key
        schemas[current_schema] = true
        fields[current_schema] = fields[current_schema] or {}
        enums[current_schema] = enums[current_schema] or {}
      end

      -- Detect properties
      if key == "properties" then
        in_enum = false
      elseif in_schemas and indent_level >= 8 and key:match("^[%w_]+$") and current_schema then
        table.insert(fields[current_schema], key)
      end

      -- Detect enum
      if key == "enum" then
        in_enum = true
      elseif key ~= "enum" and key:match("^[%w_]+$") and indent_level < 8 then
        in_enum = false
      end

      -- Count emoji
      for _ in value:gmatch("[\226-\229][\128-\191][\128-\191]") do
        emoji_count = emoji_count + 1
      end
    end

    ::continue::
  end

  local line_count = select(2, content:gsub("[^\r\n]+", "")) + (content ~= "" and 1 or 0)

  return {
    paths = paths,
    methods = methods,
    schemas = schemas,
    fields = fields,
    enums = enums,
    responses = responses,
    emoji_count = emoji_count,
    line_count = line_count
  }
end

-- =============================================================================
-- Diff Engine with Severity Classification
-- =============================================================================

local function compute_diff(left, right)
  local changes = {}

  local left_paths = {}
  for _, item in ipairs(left.paths) do left_paths[item.path] = item end
  local right_paths = {}
  for _, item in ipairs(right.paths) do right_paths[item.path] = item end

  -- Removed paths = breaking
  for path, _ in pairs(left_paths) do
    if not right_paths[path] then
      table.insert(changes, {
        type = "removed_path", severity = "breaking", path = path,
        description = "Removed path: " .. path
      })
    end
  end

  -- Added paths = non_breaking
  for path, _ in pairs(right_paths) do
    if not left_paths[path] then
      table.insert(changes, {
        type = "added_path", severity = "non_breaking", path = path,
        description = "Added path: " .. path
      })
    end
  end

  -- Compare methods on common paths
  for path, _ in pairs(left_paths) do
    if right_paths[path] then
      local lm = {}; for _, m in ipairs(left.methods[path] or {}) do lm[m] = true end
      local rm = {}; for _, m in ipairs(right.methods[path] or {}) do rm[m] = true end
      for m, _ in pairs(lm) do
        if not rm[m] then
          table.insert(changes, {
            type = "removed_method", severity = "breaking", path = path, method = m,
            description = "Removed method: " .. string.upper(m) .. " " .. path
          })
        end
      end
      for m, _ in pairs(rm) do
        if not lm[m] then
          table.insert(changes, {
            type = "added_method", severity = "non_breaking", path = path, method = m,
            description = "Added method: " .. string.upper(m) .. " " .. path
          })
        end
      end
    end
  end

  -- Compare response codes
  for path, left_codes in pairs(left.responses) do
    local rc = {}; for _, c in ipairs(right.responses[path] or {}) do rc[c] = true end
    for _, c in ipairs(left_codes) do
      if not rc[c] then
        table.insert(changes, {
          type = "removed_response", severity = "breaking", path = path,
          description = "Removed response code " .. c .. " from " .. path
        })
      end
    end
  end

  -- Compare schema fields
  for schema, lf in pairs(left.fields) do
    local rf = {}; for _, f in ipairs(right.fields[schema] or {}) do rf[f] = true end
    for _, f in ipairs(lf) do
      if not rf[f] then
        table.insert(changes, {
          type = "removed_field", severity = "breaking", schema = schema,
          description = "Removed field '" .. f .. "' from schema '" .. schema .. "'"
        })
      end
    end
    local lfs = {}; for _, f in ipairs(lf) do lfs[f] = true end
    for _, f in ipairs(right.fields[schema] or {}) do
      if not lfs[f] then
        table.insert(changes, {
          type = "added_field", severity = "non_breaking", schema = schema,
          description = "Added optional field '" .. f .. "' to schema '" .. schema .. "'"
        })
      end
    end
  end

  -- Compare enum values
  for schema, le in pairs(left.enums) do
    local re = {}; for _, v in ipairs(right.enums[schema] or {}) do re[v] = true end
    for _, v in ipairs(le) do
      if not re[v] then
        table.insert(changes, {
          type = "narrowed_enum", severity = "breaking", schema = schema,
          description = "Narrowed enum in '" .. schema .. "': removed value '" .. v .. "'"
        })
      end
    end
    local les = {}; for _, v in ipairs(le) do les[v] = true end
    for _, v in ipairs(right.enums[schema] or {}) do
      if not les[v] then
        table.insert(changes, {
          type = "widened_enum", severity = "non_breaking", schema = schema,
          description = "Widened enum in '" .. schema .. "': added value '" .. v .. "'"
        })
      end
    end
  end

  -- Informational: emoji/line changes
  local emoji_diff = right.emoji_count - left.emoji_count
  if emoji_diff ~= 0 then
    table.insert(changes, {
      type = "emoji_change", severity = "informational",
      description = "Emoji count changed by " .. emoji_diff
    })
  end
  local line_diff = right.line_count - left.line_count
  if line_diff ~= 0 then
    table.insert(changes, {
      type = "line_change", severity = "informational",
      description = "Line count changed by " .. line_diff
    })
  end

  -- Sort: breaking first, then non_breaking, then informational
  local order = { breaking = 1, non_breaking = 2, informational = 3 }
  table.sort(changes, function(a, b)
    if a.severity ~= b.severity then return order[a.severity] < order[b.severity] end
    return a.description < b.description
  end)

  local summary = { breaking = 0, non_breaking = 0, informational = 0 }
  for _, c in ipairs(changes) do summary[c.severity] = (summary[c.severity] or 0) + 1 end

  return { changes = changes, summary = summary }
end

-- =============================================================================
-- Output: Text Format
-- =============================================================================

local function print_text(diff, left_name, right_name)
  print("")
  print(DIFF_COLOR_META .. "=== OpenAPI Spec Diff Report ===" .. DIFF_COLOR_RESET)
  print("  Left:  " .. left_name)
  print("  Right: " .. right_name)
  print("")
  print(DIFF_COLOR_META .. "=== Summary ===" .. DIFF_COLOR_RESET)
  print("  Breaking:       " .. diff.summary.breaking)
  print("  Non-breaking:   " .. diff.summary.non_breaking)
  print("  Informational:  " .. diff.summary.informational)
  print("")

  local groups = { breaking = {}, non_breaking = {}, informational = {} }
  for _, c in ipairs(diff.changes) do table.insert(groups[c.severity], c) end

  if #groups.breaking > 0 then
    print(DIFF_COLOR_BREAK .. "=== Breaking Changes ===" .. DIFF_COLOR_RESET)
    for _, c in ipairs(groups.breaking) do
      print(DIFF_COLOR_BREAK .. "  [BREAKING] " .. c.description .. DIFF_COLOR_RESET)
    end
    print("")
  end
  if #groups.non_breaking > 0 then
    print(DIFF_COLOR_ADD .. "=== Non-Breaking Changes ===" .. DIFF_COLOR_RESET)
    for _, c in ipairs(groups.non_breaking) do
      print(DIFF_COLOR_ADD .. "  [OK] " .. c.description .. DIFF_COLOR_RESET)
    end
    print("")
  end
  if #groups.informational > 0 then
    print(DIFF_COLOR_META .. "=== Informational ===" .. DIFF_COLOR_RESET)
    for _, c in ipairs(groups.informational) do
      print(DIFF_COLOR_META .. "  [INFO] " .. c.description .. DIFF_COLOR_RESET)
    end
    print("")
  end
  if #diff.changes == 0 then
    print("  No changes detected. The API is stable.")
    print("")
  end
end

-- =============================================================================
-- Output: JSON Format (deterministic)
-- =============================================================================

local function escape_json(s)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return s
end

local function print_json(diff, left_name, right_name)
  local parts = {}
  table.insert(parts, '{')
  table.insert(parts, '  "left": "' .. escape_json(left_name) .. '",')
  table.insert(parts, '  "right": "' .. escape_json(right_name) .. '",')
  table.insert(parts, '  "summary": {')
  table.insert(parts, '    "breaking": ' .. diff.summary.breaking .. ',')
  table.insert(parts, '    "non_breaking": ' .. diff.summary.non_breaking .. ',')
  table.insert(parts, '    "informational": ' .. diff.summary.informational)
  table.insert(parts, '  },')
  table.insert(parts, '  "changes": [')
  for i, c in ipairs(diff.changes) do
    local comma = i < #diff.changes and "," or ""
    local path_str = c.path and (', "path": "' .. escape_json(c.path) .. '"') or ""
    local method_str = c.method and (', "method": "' .. c.method .. '"') or ""
    local schema_str = c.schema and (', "schema": "' .. escape_json(c.schema) .. '"') or ""
    table.insert(parts, string.format(
      '    {"type": "%s", "severity": "%s", "description": "%s"%s%s%s}%s',
      c.type, c.severity, escape_json(c.description), path_str, method_str, schema_str, comma
    ))
  end
  table.insert(parts, '  ]')
  table.insert(parts, '}')
  print(table.concat(parts, "\n"))
end

-- =============================================================================
-- Main
-- =============================================================================

local args = {...}
local left_file, right_file
local format = "text"

for i, arg in ipairs(args) do
  if arg == "--left" and i < #args then left_file = args[i + 1]
  elseif arg == "--right" and i < #args then right_file = args[i + 1]
  elseif arg == "--format" and i < #args then format = args[i + 1]
  elseif arg == "--self" and i < #args then left_file = args[i + 1]; right_file = args[i + 1]
  elseif arg == "--help" then
    print("Tent of Trials OpenAPI Diff Tool")
    print("")
    print("Usage:")
    print("  lua tools/openapi_diff.lua --left old.yaml --right new.yaml [--format text|json]")
    print("  lua tools/openapi_diff.lua --self v3.yaml [--format text|json]")
    print("")
    print("Formats: text (default, colorized) | json (deterministic for CI)")
    os.exit(0)
  end
end

if not left_file then
  io.stderr:write("[Diff] No input files specified. Use --help for usage.\n")
  os.exit(1)
end

local left = parse_yaml_keywords(left_file)
local right = parse_yaml_keywords(right_file or left_file)
local diff = compute_diff(left, right)

if format == "json" then
  print_json(diff, left_file, right_file or left_file)
else
  print_text(diff, left_file, right_file or left_file)
end
