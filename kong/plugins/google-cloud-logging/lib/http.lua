--- HTTP client for Google Cloud Logging API interactions.
-- Provides a simplified interface for making authenticated HTTP requests to Google's API.
-- @module kong.plugins.google-cloud-logging.lib.http
local http = require "resty.http"
local cjson = require "cjson"
local utils = require "kong.plugins.google-cloud-logging.utils.retry"
local logger = require "kong.plugins.google-cloud-logging.utils.logger"

local timer_at = ngx.timer.at
local ngx_time = ngx.time
local ngx_now = ngx.now
local ngx_update_time = ngx.update_time
local table_insert = table.insert
local table_concat = table.concat
local string_format = string.format

-- Default HTTP client settings
local DEFAULT_TIMEOUT = 10000   -- 10 seconds
local DEFAULT_KEEPALIVE_IDLE_TIMEOUT = 60000  -- 60 seconds
local DEFAULT_KEEPALIVE_POOL_SIZE = 10
local DEFAULT_RETRY_COUNT = 3

--- GoogleHttpClient implementation.
-- @type GoogleHttpClient
local GoogleHttpClient = {}

--- Creates a new HTTP client for Google Cloud API requests.
-- @param oauth_client (table) OAuth client for authentication
-- @param options (table) Configuration options for the HTTP client
-- @return (table) New GoogleHttpClient instance
function GoogleHttpClient:new(oauth_client, options)
  if not oauth_client then
    return nil, "No OAuth client provided"
  end
  
  local instance = {
    oauth_client = oauth_client,
    options = options or {}
  }
  
  -- Set defaults for options if not provided
  instance.options.timeout = instance.options.timeout or DEFAULT_TIMEOUT
  instance.options.keepalive_idle_timeout = instance.options.keepalive_idle_timeout or DEFAULT_KEEPALIVE_IDLE_TIMEOUT
  instance.options.keepalive_pool_size = instance.options.keepalive_pool_size or DEFAULT_KEEPALIVE_POOL_SIZE
  instance.options.retry_count = instance.options.retry_count or DEFAULT_RETRY_COUNT
  
  -- Set SSL verification default (true if not explicitly set)
  if instance.options.ssl_verify == nil then
    instance.options.ssl_verify = true
  end
  
  -- Get project ID from OAuth client for convenience
  instance.project_id = oauth_client.project_id
  
  -- Initialize base URL with the one provided in options, or use the default
  instance.base_url = instance.options.base_url or "https://logging.googleapis.com/v2"
  
  -- Log client creation
  logger.debug("Created HTTP client for Google Cloud API", "GoogleHttpClient")
  
  setmetatable(instance, { __index = self })
  return instance
end

--- Makes an HTTP request to a Google Cloud API.
-- @param self (table) GoogleHttpClient instance
-- @param method (string) HTTP method (GET, POST, etc.)
-- @param path (string) API endpoint path
-- @param body (table|nil) Request body (for POST/PUT)
-- @param headers (table|nil) Additional headers
-- @return (table) HTTP response
-- @return (string|nil) Error message on failure
function GoogleHttpClient:request(method, path, body, headers)
  -- Get authentication token
  local token, err = self.oauth_client:get_access_token()
  if err then
    logger.warn("Failed to get access token: " .. err, "GoogleHttpClient")
  end
  if not token then
    return nil, "Failed to get access token: " .. (err or "unknown error")
  end
  -- Create HTTP client
  local httpc = http.new()
  httpc:set_timeout(self.options.timeout)
  
  -- Prepare complete URL
  local url
  if path:sub(1, 8) == "https://" then
    url = path  -- Path is already a full URL
  else
    url = self.base_url .. path
  end
  
  -- Prepare headers
  local request_headers = {
    ["Authorization"] = "Bearer " .. token,
    ["Content-Type"] = "application/json",
    ["User-Agent"] = "kong-plugin-google-cloud-logging/0.1"
  }
  
  -- Add any additional headers
  if headers then
    for k, v in pairs(headers) do
      request_headers[k] = v
    end
  end
  
  -- Prepare request body
  local request_body
  if body then
    request_body = cjson.encode(body)
    
    -- Log detailed request information for debugging
    logger.debug("API Request to: " .. url, "GoogleHttpClient")
    logger.debug("API Request method: " .. method, "GoogleHttpClient")
    
    -- Log a preview of the request body (limited to prevent huge logs)
    local max_body_log_size = self.options.max_body_log_size or 2000
    local body_preview = request_body
    if #body_preview > max_body_log_size then
      body_preview = body_preview:sub(1, max_body_log_size) .. "... (truncated)"
    end
    logger.debug("API Request body: " .. body_preview, "GoogleHttpClient")
  end
  
  -- Log the request details
  logger.debug(string_format("[%s %s] Making request", method, path), "GoogleHttpClient")
  
  -- Retry loop for failed requests - Fix how we call the retry function
  local retry_opts = {
    max_attempts = self.options.retry_count or 3,
    base_delay_ms = 100,
    max_delay_ms = 10000,
    jitter_factor = 0.2
  }
  
  -- Call with_retries with the proper arguments
  return utils.with_retries(function()
    -- Make the request
    local res, request_err = httpc:request_uri(url, {
      method = method,
      body = request_body,
      headers = request_headers,
      ssl_verify = self.options.ssl_verify
    })
    
    -- Handle request errors
    if not res then
      logger.warn(string_format("[%s %s] Request failed: %s", 
        method, path, request_err or "unknown error"), "GoogleHttpClient")
      return nil, request_err
    end
    
    -- Log the response for debugging
    logger.debug("API Response status: " .. res.status, "GoogleHttpClient")
    local response_preview = res.body or ""
    local max_body_log_size = self.options.max_body_log_size or 2000
    if #response_preview > max_body_log_size then
      response_preview = response_preview:sub(1, max_body_log_size) .. "... (truncated)"
    end
    logger.debug("API Response body: " .. response_preview, "GoogleHttpClient")
    
    -- Handle non-successful responses
    if res.status < 200 or res.status >= 300 then
      local err_msg = string_format("HTTP %d: %s", res.status, res.body)
      logger.warn(string_format("[%s %s] Request failed: %s", 
        method, path, err_msg), "GoogleHttpClient")
      return nil, err_msg, res.status
    end
    
    -- Log full response headers for debugging
    logger.debug("API Response headers:", "GoogleHttpClient")
    for k, v in pairs(res.headers) do
      logger.debug(string_format("  %s: %s", k, v), "GoogleHttpClient")
    end
    
    -- Set keepalive
    httpc:set_keepalive(
      self.options.keepalive_idle_timeout,
      self.options.keepalive_pool_size)
    
    -- Parse response body if it exists
    local response_body
    if res.body and res.body ~= "" then
      local ok, parsed = pcall(cjson.decode, res.body)
      if ok then
        response_body = parsed
      else
        logger.warn("Failed to parse response body as JSON: " .. parsed, "GoogleHttpClient")
        response_body = res.body
      end
    end
    
    -- Log success
    logger.debug(string_format("[%s %s] Request successful (HTTP %d)", 
      method, path, res.status), "GoogleHttpClient")
    
    -- Return both full response and parsed body
    return {
      status = res.status,
      headers = res.headers,
      body = response_body,
      raw_body = res.body
    }
  end, retry_opts)
end

--- Make a GET request to a Google Cloud API.
-- @param self (table) GoogleHttpClient instance
-- @param path (string) API endpoint path
-- @param headers (table|nil) Additional headers
-- @return (table) HTTP response
-- @return (string|nil) Error message on failure
function GoogleHttpClient:get(path, headers)
  return self:request("GET", path, nil, headers)
end

--- Make a POST request to a Google Cloud API.
-- @param self (table) GoogleHttpClient instance
-- @param path (string) API endpoint path
-- @param body (table|nil) Request body
-- @param headers (table|nil) Additional headers
-- @return (table) HTTP response
-- @return (string|nil) Error message on failure
function GoogleHttpClient:post(path, body, headers)
  return self:request("POST", path, body, headers)
end

--- Make a PUT request to a Google Cloud API.
-- @param self (table) GoogleHttpClient instance
-- @param path (string) API endpoint path
-- @param body (table|nil) Request body
-- @param headers (table|nil) Additional headers
-- @return (table) HTTP response
-- @return (string|nil) Error message on failure
function GoogleHttpClient:put(path, body, headers)
  return self:request("PUT", path, body, headers)
end

--- Make a DELETE request to a Google Cloud API.
-- @param self (table) GoogleHttpClient instance
-- @param path (string) API endpoint path
-- @param headers (table|nil) Additional headers
-- @return (table) HTTP response
-- @return (string|nil) Error message on failure
function GoogleHttpClient:delete(path, headers)
  return self:request("DELETE", path, nil, headers)
end

--- Factory function to create a new GoogleHttpClient.
-- @param oauth_client (table) OAuth client for authentication
-- @param options (table) Configuration options for the HTTP client
-- @return (table) New GoogleHttpClient instance
-- @return (string|nil) Error message on failure
return function(oauth_client, options)
  return GoogleHttpClient:new(oauth_client, options)
end