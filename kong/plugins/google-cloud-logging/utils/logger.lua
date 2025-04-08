--- Logging utility module for Kong Google Cloud Logging plugin.
-- Provides standardized logging methods with context support.
-- @module kong.plugins.google-cloud-logging.utils.logger
local json_parser = require "kong.plugins.google-cloud-logging.utils.json_parser"

local _M = {}

--- Internal log helper function.
-- @param level (string) Log level: debug, info, warn, err, crit
-- @param message (string) Message to log
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
local function log_with_context(level, message, context, details)
  local kong = kong
  
  if not kong or not kong.log then
    -- Fallback to print if not running in Kong context (e.g., unit tests)
    local formatted_level = string.upper(level)
    print(formatted_level .. ": " .. message)
    return
  end
  
  -- Format message with context if provided
  local formatted_message
  if context then
    formatted_message = "[" .. context .. "] " .. message
  else
    formatted_message = message
  end
  
  -- Include details as JSON if provided
  if details then
    local details_json = json_parser.safe_json_encode(details)
    formatted_message = formatted_message .. " - Details: " .. details_json
  end
  
  -- Call appropriate Kong logging method
  if level == "debug" then
    kong.log.debug(formatted_message)
  elseif level == "info" then
    kong.log.info(formatted_message)
  elseif level == "notice" then
    kong.log.notice(formatted_message)
  elseif level == "warn" then
    kong.log.warn(formatted_message)
  elseif level == "err" then
    kong.log.err(formatted_message)
  elseif level == "crit" then
    kong.log.crit(formatted_message)
  else
    kong.log.notice(formatted_message) -- Default to notice for unknown levels
  end
end

--- Log a debug message.
-- @param message (string) Debug message
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
function _M.debug(message, context, details)
  log_with_context("debug", message, context, details)
end

--- Log an info message.
-- @param message (string) Info message
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
function _M.info(message, context, details)
  log_with_context("info", message, context, details)
end

--- Log a notice message.
-- @param message (string) Notice message
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
function _M.notice(message, context, details)
  log_with_context("notice", message, context, details)
end

--- Log a warning message.
-- @param message (string) Warning message
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
function _M.warn(message, context, details)
  log_with_context("warn", message, context, details)
end

--- Log an error message.
-- @param message (string) Error message
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
function _M.err(message, context, details)
  log_with_context("err", message, context, details)
end

--- Log a critical message.
-- @param message (string) Critical message
-- @param context (string) Optional context tag
-- @param details (table) Optional details table
function _M.crit(message, context, details)
  log_with_context("crit", message, context, details)
end

--- Log a table as JSON with detailed error handling.
-- @param name (string) Name to identify the logged table
-- @param data (table) Table to log
-- @param context (string) Optional context tag
function _M.log_table(name, data, context)
  local encoded = json_parser.safe_json_encode(data)
  log_with_context("debug", name .. ": " .. encoded, context)
end

--- Extended error logging for structured errors.
-- @param err (table|string) Error object or message
-- @param context (string) Optional context tag
function _M.log_detailed_error(err, context)
  if type(err) == "table" then
    -- Table-style error
    if err.status and err.message then
      -- Structured error from API
      log_with_context("err", "Error " .. err.status .. ": " .. err.message, context, err)
    else
      -- Generic table-style error
      log_with_context("err", "Error occurred", context, err)
    end
  else
    -- String error
    log_with_context("err", tostring(err), context)
  end
end

--- Log debug information about request/response body.
-- @param body_type (string) Type of body (request/response)
-- @param body (string) The body content
-- @param parsed_type (string) Type of the parsed content
function _M.debug_body_info(body_type, body, parsed_type)
  if not kong.log.debug then
    return -- Skip if debug logging is disabled
  end
  
  local sample_size = 100 -- Only show first 100 chars to avoid flooding logs
  local body_preview = body and #body > 0 and body:sub(1, sample_size) or "(empty)"
  if #body > sample_size then
    body_preview = body_preview .. "... (truncated, total size: " .. #body .. " bytes)"
  end
  
  log_with_context(
    "debug", 
    "Logging " .. body_type .. " body, parsed as " .. parsed_type .. ". Preview: " .. body_preview, 
    "body_logger"
  )
end

--- Fallback logger for when Google Cloud Logging is not available.
-- @param entry (table) Log entry object
function _M.fallback_log(entry)
  -- Extract the most important parts of the entry for local logging
  local method = entry.request and entry.request.requestMethod or "UNKNOWN"
  local status = entry.request and entry.request.status or 0
  local url = entry.request and entry.request.requestUrl or "unknown_url"
  local severity = entry.severity or "INFO"
  
  -- Create a simplified log message
  local message = string.format(
    "[FALLBACK] %s - %s %s - Status: %d", 
    severity, 
    method, 
    url, 
    status
  )
  
  -- Log with appropriate severity level
  if severity == "ERROR" then
    kong.log.err(message)
  elseif severity == "WARNING" then
    kong.log.warn(message)
  else
    kong.log.info(message)
  end
end

return _M