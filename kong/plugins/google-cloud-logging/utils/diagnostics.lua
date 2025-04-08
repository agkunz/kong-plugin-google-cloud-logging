--- Diagnostics utility module for Kong Google Cloud Logging plugin.
-- Provides diagnostic and debugging functions for troubleshooting.
-- @module kong.plugins.google-cloud-logging.utils.diagnostics
local OAuth = require "kong.plugins.google-cloud-logging.lib.oauth"
local HTTPClient = require "kong.plugins.google-cloud-logging.lib.http"
local socket = require "socket"
local json_parser = require "kong.plugins.google-cloud-logging.utils.json_parser"

local kong = kong

local _M = {}

--- Get a table with runtime information about the Kong node.
-- @return (table) Kong node information
function _M.get_kong_info()
  return {
    version = kong and kong.version or "unknown",
    server_info = ngx and ngx.config and ngx.config.nginx_version and 
                  ("nginx/" .. ngx.config.nginx_version) or "unknown"
  }
end

--- Get a table with runtime information about the plugin.
-- @param plugin_conf (table) Plugin configuration
-- @return (table) Plugin information
function _M.get_plugin_info(plugin_conf)
  local info = {
    name = "google-cloud-logging",
    config = {}
  }
  
  -- Include sanitized config (remove sensitive info)
  if plugin_conf then
    -- Deep copy the configuration
    for k, v in pairs(plugin_conf) do
      if k ~= "service_account" and k ~= "private_key" then
        info.config[k] = v
      else
        info.config[k] = "[REDACTED]"
      end
    end
  end
  
  return info
end

--- Get a table with runtime information about the system.
-- @return (table) System information
function _M.get_system_info()
  return {
    lua_version = _VERSION,
    os_time = os.time(),
    pid = ngx.worker.pid()
  }
end

--- Create a diagnostic report containing environment information.
-- @param plugin_conf (table) Plugin configuration
-- @return (string) JSON string with diagnostic information
function _M.create_diagnostic_report(plugin_conf)
  local report = {
    timestamp = ngx.time(),
    kong = _M.get_kong_info(),
    plugin = _M.get_plugin_info(plugin_conf),
    system = _M.get_system_info()
  }
  
  local json, err = json_parser.safe_json_encode(report)
  if not json then
    logger.err("Failed to encode diagnostic report: " .. (err or "unknown error"), "Diagnostics")
    return "{\"error\": \"Failed to encode diagnostic report\"}"
  end
  
  return json
end

--- Log detailed diagnostic information for an error.
-- @param err (string) Error message
-- @param component (string) Component that generated the error
-- @param context (table) Additional contextual information
function _M.log_error_details(err, component, context)
  local details = {
    error = err,
    component = component,
    timestamp = ngx.time(),
    context = context or {}
  }
  
  local json, encode_err = json_parser.safe_json_encode(details)
  if not json then
    logger.err("Error diagnostic encoding failed: " .. (encode_err or "unknown error"), "Diagnostics")
    logger.err("Original error: " .. (err or "unknown error"), component)
    return
  end
  
  logger.err("Error details: " .. json, "Diagnostics")
end

--- Test Google Cloud Logging connectivity and report results.
-- @param plugin_conf (table) Plugin configuration
-- @return (boolean) True if successful, false otherwise
-- @return (string) Error message if unsuccessful
function _M.test_connectivity(plugin_conf)
  -- Implementation would depend on specific Google Cloud Logging API
  -- This is a placeholder for the actual implementation
  logger.info("Testing Google Cloud Logging connectivity", "Diagnostics")
  
  -- Mock implementation for clarity
  local success = false
  local error_message = "Test connectivity function not implemented"
  
  logger.info("Connectivity test result: " .. (success and "Success" or "Failed: " .. error_message), 
             "Diagnostics")
  
  return success, error_message
end

-- Helper function to send a diagnostic log entry directly to Google Cloud
-- Bypasses the batch queue to help identify authentication or network issues
-- @param conf Plugin configuration
-- @return success boolean, response body, status code
function _M.send_test_log(conf)
  local cloud_logger = require "kong.plugins.google-cloud-logging.cloud_logger"
  local key = cloud_logger.get_key(conf)
  
  -- Check if we have a valid key
  if not key or not key.private_key or not key.client_email or not key.project_id then
    kong.log.err("Google-cloud-logging diagnostics: No valid Google credentials available")
    return false, "No valid Google credentials", nil
  end
  
  kong.log.notice("Google-cloud-logging diagnostics: Sending test log entry using account " .. key.client_email)
  
  -- Create OAuth instance
  local scope = "https://www.googleapis.com/auth/logging.write"
  local oauth, err
  
  local ok, create_err = pcall(function()
    oauth = OAuth(nil, key, scope)
  end)
  
  if not ok or not oauth then
    kong.log.err("Google-cloud-logging diagnostics: Failed to create OAuth object: " .. (create_err or "unknown error"))
    return false, "Failed to create OAuth object: " .. (create_err or "unknown error"), nil
  end
  
  -- Create a test log entry
  local timestamp = os.time()
  local isoTime = os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
  
  -- Get resource from config or use global resource
  local resource = conf.resource or {
    type = "global",
    labels = {}
  }
  
  -- Create a simple diagnostic payload
  local test_entry = {
    {
      logName = "projects/" .. key.project_id .. "/logs/kong-plugin-google-cloud-logging-diagnostic-test",
      resource = resource,
      timestamp = isoTime,
      labels = {
        source = "kong-plugin-google-cloud-logging-diagnostic"
      },
      jsonPayload = {
        message = "This is a diagnostic test log entry from Kong Google Cloud Logging plugin",
        timestamp = timestamp,
        client_email = key.client_email,
        test_id = tostring(math.random(10000, 99999))
      }
    }
  }
  
  -- Send directly to Google Cloud Logging API
  local logging_client = HTTPClient(oauth, "https://logging.googleapis.com/v2/")
  kong.log.notice("Google-cloud-logging diagnostics: Sending test log to Google Cloud Logging API...")
  
  local response, code = logging_client:Request("entries:write", {
    entries = test_entry,
    partialSuccess = false,
  }, nil, "POST")
  
  if code ~= 200 then
    local err_msg = "Failed to send test log"
    if type(response) == "table" then
      pcall(function()
        err_msg = err_msg .. ": " .. json_parser.encode(response)
      end)
    elseif type(response) == "string" then
      err_msg = err_msg .. ": " .. response
    end
    
    kong.log.err("Google-cloud-logging diagnostics error: " .. err_msg .. " (code: " .. (code or "unknown") .. ")")
    
    if code == 401 or code == 403 then
      kong.log.err("Google-cloud-logging diagnostics: Authentication failed. Check credentials and permissions.")
    end
    
    return false, err_msg, code
  end
  
  kong.log.notice("Google-cloud-logging diagnostics: Test log entry sent successfully!")
  kong.log.notice("Google-cloud-logging diagnostics: Check Google Cloud Logging for entries with label source=kong-plugin-google-cloud-logging-diagnostic")
  
  return true, response, code
end

-- Add a function that dumps the actual request and response for debugging
function _M.debug_api_request(conf, test_payload)
  local key = require("kong.plugins.google-cloud-logging.cloud_logger").get_key(conf)
  
  -- Ensure we have valid credentials
  if not key or not key.private_key or not key.client_email or not key.project_id then
    kong.log.err("Google-cloud-logging diagnostics: No valid Google credentials available")
    return false, "No valid Google credentials", nil
  end
  
  -- Create OAuth instance
  local OAuth = require "kong.plugins.google-cloud-logging.lib.oauth"
  local HTTPClient = require "kong.plugins.google-cloud-logging.lib.http"
  local scope = "https://www.googleapis.com/auth/logging.write"
  local oauth
  
  local ok, create_err = pcall(function()
    oauth = OAuth(nil, key, scope)
  end)
  
  if not ok or not oauth then
    kong.log.err("Google-cloud-logging diagnostics: Failed to create OAuth object: " .. (create_err or "unknown error"))
    return false, "Failed to create OAuth object: " .. (create_err or "unknown error"), nil
  end
  
  -- Create a simple test log entry if none provided
  if not test_payload then
    local timestamp = os.time()
    local isoTime = os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
    
    -- Get resource from config or use global resource
    local resource = conf.resource or {
      type = "global",
      labels = { project_id = key.project_id }
    }
    
    test_payload = {
      entries = {
        {
          logName = "projects/" .. key.project_id .. "/logs/kong-plugin-google-cloud-logging-debug",
          resource = resource,
          timestamp = isoTime,
          labels = {
            source = "kong-plugin-google-cloud-logging-debug"
          },
          jsonPayload = {
            message = "Debug test log entry from Kong Google Cloud Logging plugin",
            timestamp = timestamp,
            client_email = key.client_email,
            test_id = tostring(math.random(10000, 99999))
          },
          severity = "DEBUG"
        }
      }
    }
  end
  
  -- Enable verbose HTTP logging
  kong.log.notice("Google-cloud-logging diagnostics: Sending debug log with verbose output")
  
  -- Send directly to Google Cloud Logging API and capture full request/response
  local logging_client = HTTPClient(oauth, "https://logging.googleapis.com/v2/")
  
  local json_body = json_parser.encode(test_payload)
  kong.log.notice("Google-cloud-logging diagnostics: REQUEST PAYLOAD:")
  kong.log.notice(json_body)
  
  local response, code = logging_client:Request("entries:write", test_payload, nil, "POST")
  
  kong.log.notice("Google-cloud-logging diagnostics: RESPONSE STATUS: " .. (code or "nil"))
  kong.log.notice("Google-cloud-logging diagnostics: RESPONSE BODY:")
  
  if type(response) == "table" then
    local resp_json = json_parser.encode(response)
    kong.log.notice(resp_json)
  else
    kong.log.notice(tostring(response))
  end
  
  if code ~= 200 then
    kong.log.err("Google-cloud-logging diagnostics: Request failed with code " .. (code or "unknown"))
    return false, response, code
  end
  
  kong.log.notice("Google-cloud-logging diagnostics: Test request completed successfully (HTTP 200)")
  return true, response, code
end

-- Verify resource configuration is valid
-- @param resource Resource configuration table
-- @return valid boolean, error string
function _M.validate_resource(resource)
  if not resource then
    return false, "Resource configuration is missing"
  end
  
  if not resource.type then
    return false, "Resource type is required"
  end
  
  -- Check for common resource types that require specific labels
  if resource.type == "k8s_container" then
    local required_labels = {"project_id", "location", "cluster_name", "namespace_name", "pod_name", "container_name"}
    for _, label in ipairs(required_labels) do
      if not resource.labels or not resource.labels[label] then
        return false, "Resource type '" .. resource.type .. "' requires label '" .. label .. "'"
      end
    end
  elseif resource.type == "gce_instance" then
    local required_labels = {"project_id", "instance_id", "zone"}
    for _, label in ipairs(required_labels) do
      if not resource.labels or not resource.labels[label] then
        return false, "Resource type '" .. resource.type .. "' requires label '" .. label .. "'"
      end
    end
  elseif resource.type == "global" then
    -- Global resource type requires project_id
    if not resource.labels or not resource.labels.project_id then
      return false, "Resource type 'global' requires label 'project_id'"
    end
  end
  
  return true, nil
end

-- Get diagnostic information about plugin configuration
-- @param conf Plugin configuration
-- @return diagnostic_info table
function _M.get_diagnostic_info(conf)
  local cloud_logger = require "kong.plugins.google-cloud-logging.cloud_logger"
  local key = cloud_logger.get_key(conf)
  
  local info = {
    has_credentials = false,
    project_id = nil,
    client_email = nil,
    resource_type = conf.resource and conf.resource.type or nil,
    resource_labels = {},
    batch_config = {
      batch_max_size = conf.batch_max_size,
      flush_timeout = conf.flush_timeout,
      retry_count = conf.retry_count
    },
    retry_config = {
      max_attempts = conf.retry_max_attempts,
      base_delay = conf.retry_base_delay,
      max_delay = conf.retry_max_delay
    },
    log_config = {
      log_request_body = conf.log_request_body,
      log_response_body = conf.log_response_body,
      log_request_headers = conf.log_request_headers,
      log_response_headers = conf.log_response_headers
    }
  }
  
  -- Check credentials
  if key and key.private_key and key.client_email and key.project_id then
    info.has_credentials = true
    info.project_id = key.project_id
    info.client_email = key.client_email
  end
  
  -- Check resource configuration
  if conf.resource and conf.resource.labels then
    info.resource_labels = conf.resource.labels
  end
  
  -- Check resource validity
  local resource_valid, resource_error = _M.validate_resource(conf.resource)
  info.resource_valid = resource_valid
  info.resource_error = resource_error
  
  return info
end

return _M