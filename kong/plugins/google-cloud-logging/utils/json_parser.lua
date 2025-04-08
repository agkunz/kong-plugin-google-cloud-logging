--- JSON parsing utility module for Kong Google Cloud Logging plugin.
-- Provides robust JSON encoding and decoding with error handling capabilities.
-- @module kong.plugins.google-cloud-logging.utils.json_parser
local cjson = require "cjson"
local _M = {}

--- Parse a JSON string into a Lua table with robust error handling.
-- If parsing fails, tries multiple methods to handle quoted/escaped JSON.
-- @param str (string) String potentially containing JSON
-- @return (table|string) Parsed table or original string if parsing fails
function _M.parse_json(str)
  if not str then return nil end
  
  -- First try to decode directly
  local success, parsed = pcall(cjson.decode, str)
  if success then
    return parsed
  end
  
  -- If that fails, check if it's a string that contains JSON but is quoted/escaped
  if type(str) == "string" then
    -- Try to remove quotes if the string is wrapped in them
    local unquoted = str:match('^"(.+)"$') or str:match("^'(.+)'$") or str
    
    -- Try to parse again after unquoting
    success, parsed = pcall(cjson.decode, unquoted)
    if success then
      return parsed
    end
    
    -- Try to handle escaped JSON strings
    if str:match('\\\"') or str:match('\\\\') then
      local unescaped = str:gsub('\\\"', '"'):gsub('\\\\', '\\')
      success, parsed = pcall(cjson.decode, unescaped)
      if success then
        return parsed
      end
    end
  end
  
  -- Return original value if all parsing attempts fail
  return str
end

--- Encode a Lua table to JSON with error handling.
-- @param data (table) Lua table to encode
-- @return (string|nil) JSON string or nil
-- @return (string|nil) Error message if encoding fails
function _M.encode_json(data)
  local success, json_str = pcall(cjson.encode, data)
  if not success then
    return nil, "Failed to encode JSON: " .. tostring(json_str)
  end
  return json_str
end

--- Safely encode complex tables to JSON with detailed error handling.
-- If encoding fails, attempts to simplify the table and retry.
-- @param data (table|any) Lua data to encode, typically a table
-- @return (string) JSON string or simplified string representation on failure
function _M.safe_json_encode(data)
  local success, result = pcall(cjson.encode, data)
  if success then
    return result
  end
  
  -- If encoding failed, try to create a simplified version
  if type(data) == "table" then
    local simplified = {}
    for k, v in pairs(data) do
      if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
        simplified[k] = v
      else
        simplified[k] = tostring(v)
      end
    end
    
    -- Try again with simplified table
    success, result = pcall(cjson.encode, simplified)
    if success then
      return result
    end
  end
  
  -- Last resort - convert to string
  return "data-encoding-failed"
end

return _M