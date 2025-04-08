local OAuth = require "kong.plugins.google-cloud-logging.lib.oauth"
local HTTPClient = require "kong.plugins.google-cloud-logging.lib.http"
local BatchQueue = require "kong.plugins.google-cloud-logging.batch_queue"
local socket = require "socket"
local kong = kong

local logger = require "kong.plugins.google-cloud-logging.utils.logger"
local json_parser = require "kong.plugins.google-cloud-logging.utils.json_parser"
local retry = require "kong.plugins.google-cloud-logging.utils.retry"

local _M = {}

-- Helper function to get table keys for debugging
local function table_keys(t)
  local keys = {}
  for k, _ in pairs(t) do
    table.insert(keys, k)
  end
  return keys
end

-- Valid Google Cloud resource types - keep in sync with schema.lua
local VALID_RESOURCE_TYPES = {
  ["global"] = true,
  ["gce_instance"] = true, 
  ["k8s_container"] = true,
  ["k8s_cluster"] = true,
  ["gae_app"] = true,
  ["cloud_function"] = true,
  ["cloud_run_revision"] = true
}

-- Global queues for batch processing - stored by session
local queues = {}

-- Send log entries to Google Cloud Logging with retry capability
-- @param oauth OAuth object for authentication
-- @param entries Table of log entries
-- @param resource Resource to log to
-- @param log_id Log ID string
-- @param retry_opts Table of retry options
-- @param source Source string for log entries
-- @param http_opts Table of HTTP client options
-- @return success boolean, error message string (if applicable)
function _M.send_to_logging(oauth, entries, resource, log_id, retry_opts, source, http_opts)
  -- Fix: Remove the base URL parameter and set it properly in the options
  local combined_http_opts = http_opts or {}
  combined_http_opts.base_url = "https://logging.googleapis.com/v2/"
  
  local logging_client = HTTPClient(oauth, combined_http_opts)
  local log_entries = {}
  
  logger.debug("Preparing to send " .. #entries .. " entries to Google Cloud", "cloud_logger")
  
  -- Properly format log_id by URL encoding any slashes
  local formatted_log_id = log_id:gsub("/", "%%2F")
  logger.debug("Using formatted log_id: " .. formatted_log_id, "cloud_logger")
  
  for _, entry in pairs(entries) do
    local preciceSeconds = entry.timestamp
    local seconds = math.floor(preciceSeconds)
    local milliSeconds = math.floor((preciceSeconds - seconds) * 1000)
    local isoTime = os.date("!%Y-%m-%dT%T.", seconds) .. tostring(milliSeconds) .. "Z"
    
    -- Merge entry labels with source label
    local labels = { source = source }
    if entry.labels then
      for k, v in pairs(entry.labels) do
        labels[k] = v
      end
    end
    
    -- Add entry to the log_entries table with the properly formatted log_id
    table.insert(log_entries, {
      logName = "projects/" .. oauth:get_project_id() .. "/logs/" .. formatted_log_id,
      resource = resource,
      timestamp = isoTime,
      labels = labels,
      jsonPayload = entry.data,
      httpRequest = entry.request,
      severity = entry.severity
    })
  end
  
  logger.debug("Constructed log entries payload for Google Cloud", "cloud_logger")
  
  -- Define the function that will be retried
  local function send_request()
    logger.debug("Sending request to Google Cloud Logging API", "cloud_logger")
    
    -- Restore original behavior - this is how the code likely worked before our changes
    local response = logging_client:post("entries:write", {
      entries = log_entries,
      partialSuccess = false,
    })
    
    -- Force additional debugging to see what's actually being returned
    logger.debug("Response type from Google Cloud: " .. type(response), "cloud_logger")
    if type(response) == "table" then
      logger.debug("Response status: " .. (response.status or "nil"), "cloud_logger")
      
      -- Try to log response body details
      if response.body then
        if type(response.body) == "table" then
          local json_body = json_parser.encode_json(response.body)
          logger.debug("Response body (JSON): " .. json_body, "cloud_logger")
        elseif type(response.body) == "string" then
          logger.debug("Response body (raw): " .. response.body, "cloud_logger")
        else
          logger.debug("Response body type: " .. type(response.body), "cloud_logger")
        end
      else
        logger.debug("Response has no body", "cloud_logger")
      end
    else
      -- Response is not a table, might be an error string
      logger.err("Response is not a table: " .. tostring(response), "cloud_logger")
    end
    
    -- Extract code and error from response
    local code = response and response.status
    local err = nil
    
    if not response then
      err = "No response received"
    elseif type(response) == "string" then
      err = response
    elseif not code or code < 200 or code >= 300 then
      err = "HTTP error"
      if response.body then
        if type(response.body) == "table" then
          err = json_parser.encode_json(response.body)
        elseif type(response.body) == "string" then
          err = response.body
        end
      end
    end
    
    logger.debug("Received response from Google Cloud - code: " .. (code or "nil"), "cloud_logger")
    
    if err then
      logger.err("Google Cloud Logging API error: " .. err, "cloud_logger")
      return nil, err, code
    end
    
    logger.debug("Successfully sent logs to Google Cloud", "cloud_logger")
    return true
  end
  
  -- Attempt to send logs with retries
  local success, err, code, retry_count = retry.with_retries(send_request, retry_opts)
  
  if not success then
    kong.log.err("Google-cloud-logging: Failed to send logs after all retries: " .. 
      err .. (code and (" (code: " .. code .. ")") or ""))
    return false, err
  end
  
  -- Log retry information if there were retries
  if retry_count and retry_count > 0 then
    kong.log.info(string.format("Google-cloud-logging: Successfully sent logs after %d retries", retry_count))
  else
    logger.debug("Successfully sent logs to Google Cloud (no retries needed)", "cloud_logger")
  end
  
  return true
end

-- Get Google service account key
-- @param conf Plugin configuration
-- @return key The Google service account key or empty table
function _M.get_key(conf)
  local auth = conf.auth or {}
  
  -- Use the key specified in the config
  if auth.google_key then
    logger.debug("Using inline Google service account credentials")
    return auth.google_key
  end

  -- Read the key from the specified path, but consider empty string as not provided
  if auth.google_key_file and auth.google_key_file ~= "" then
    logger.debug("Loading Google service account credentials from file: " .. auth.google_key_file)
    local file_content, err
    local file = io.open(auth.google_key_file, "r")
    
    if file then
      file_content = file:read("*a")
      file:close()
    else
      kong.log.warn("Could not open Google key file: " .. (err or "file not found"))
      return {}
    end
    
    local ok, key = pcall(json_parser.parse_json, file_content)
    if not ok or not key or type(key) ~= "table" then
      kong.log.err("Failed to parse Google key file as JSON")
      return {}
    end
    
    -- Validate required fields
    if not key.private_key or not key.client_email or not key.project_id then
      kong.log.err("Google service account key file missing required fields (private_key, client_email, or project_id)")
      return {}
    end
    
    -- Ensure token_uri is present
    key.token_uri = key.token_uri or "https://oauth2.googleapis.com/token"
    
    -- Log some info for debugging
    logger.debug("Loaded service account - email: " .. key.client_email .. ", project: " .. key.project_id)
    
    return key
  end

  -- Should never get here due to schema validation
  kong.log.err("No Google credentials provided - need either google_key or google_key_file in plugin configuration")
  return {}
end

-- Create a log entry object
-- @param conf Plugin configuration
-- @return entry Log entry table
function _M.create_log_entry(conf)
  local logging_options = conf.logging_options or {}
  local memory_options = conf.memory_options or {}
  local logs = kong.log.serialize()

  -- Determine severity based on response status code
  local severity = "INFO" -- Default severity
  local status = logs.response.status
  
  if status >= 500 then
    severity = "ERROR"
  elseif status >= 400 then
    severity = "WARNING"
  elseif status >= 300 then
    severity = "NOTICE"
  elseif status >= 200 then
    severity = "INFO"
  end

  -- Initialize labels for route and service
  local entry_labels = {}
  
  -- Add route and service to labels if available
  if logs.route and logs.route.name then
    entry_labels.route = logs.route.name
  end
  
  if logs.service and logs.service.name then
    entry_labels.service = logs.service.name
  end
  
  -- Add consumer to labels if available
  if logs.consumer and logs.consumer.username then
    entry_labels.consumer = logs.consumer.username
  end

  local entry = {
    timestamp = socket.gettime(),
    data = {
      upstream_uri = logs.upstream_uri,
      uri = logs.request.uri,
      request_query = logs.request.querystring or {},
      latency = {
        request = logs.latencies.request,
        gateway = logs.latencies.kong,
        proxy = logs.latencies.proxy,
      },
    },
    request = {
      requestMethod = logs.request.method,
      requestUrl = logs.request.url,
      requestSize = logs.request.size,
      status = logs.response.status,
      responseSize = logs.response.size,
      userAgent = logs.request["user-agent"],
      remoteIp = logs.client_ip,
      serverIp = logs.tries ~= nil and #logs.tries > 0 and logs.tries[1].ip or nil,
      latency = tostring(logs.latencies.request / 1000) .. "s",
    },
    severity = severity,
    labels = entry_labels
  }

  -- Add request headers if configured
  if logging_options.log_request_headers then
    entry.data.request_headers = logs.request.headers
  end

  -- Add response headers if configured
  if logging_options.log_response_headers then
    entry.data.response_headers = logs.response.headers
  end
  
  -- Add request body if configured
  if logging_options.log_request_body then
    if ngx.ctx.request_body and #ngx.ctx.request_body > 0 then
      -- Non-empty request body: parse as JSON
      entry.data.request_body = json_parser.parse_json(ngx.ctx.request_body)
      logger.debug_body_info("request", ngx.ctx.request_body, type(entry.data.request_body))
      
      -- Add metadata about truncation if the body was truncated
      if #ngx.ctx.request_body == memory_options.max_request_body_size then
        entry.data.request_body_meta = { truncated = true, limit = memory_options.max_request_body_size }
      end
    else
      -- Empty or nil request body: use empty table instead of empty string
      entry.data.request_body = {}
      logger.debug("Empty request body, using empty table instead")
    end
  end

  -- Add response body if configured
  if logging_options.log_response_body then
    -- Use the response body storage location
    local response_body = ngx.ctx.google_logging_response_body
    if response_body and type(response_body) == "string" and #response_body > 0 then
      entry.data.response_body = json_parser.parse_json(response_body)
      logger.debug_body_info("response", response_body, type(entry.data.response_body))
      
      -- Add metadata about truncation if the body was truncated
      if ngx.ctx.google_logging_truncate_response then
        entry.data.response_body_meta = { truncated = true, limit = memory_options.max_response_body_size }
      end
    else
      if ngx.ctx.google_logging_skip_response then
        -- Response was too large and skipped
        entry.data.response_body_meta = { 
          skipped = true, 
          limit = memory_options.max_response_body_size,
          actual_size = ngx.ctx.google_logging_response_body_size or "unknown"
        }
        logger.debug("Response body was skipped due to size limit")
      else
        kong.log.warn("No response body available to log or empty response")
        -- Include contextual info to help diagnose
        entry.data.response_body_debug = {
          available = response_body ~= nil,
          type = type(response_body),
          size = response_body and type(response_body) == "string" and #response_body or 0,
          content_type = logs.response.headers and logs.response.headers["Content-Type"] or "unknown",
          response_size = logs.response.size
        }
      end
    end
  end

  -- Add protocol from service
  if logs.service then
    entry.request.protocol = logs.service.protocol
  end

  return entry
end

-- Get or create a queue for batch processing logs
-- @param conf Plugin configuration
-- @return queue The batch queue object
function _M.get_queue(conf)
  local auth = conf.auth or {}
  local logging_config = conf.logging_config or {}
  local batch_options = conf.batch_options or {}
  local retry_options = conf.retry_options or {}
  local http_options = conf.http_options or {}
  
  local sessionKey = 'default'
  local key = _M.get_key(conf)
  
  -- Check if we have a valid key with required fields
  local has_valid_key = key and type(key) == "table" and key.private_key and key.client_email and key.project_id
  
  -- If no key provided or key file doesn't exist, still log but without Google Cloud integration
  if not has_valid_key then
    logger.err("No valid Google credentials - logging to Kong's logs without Google Cloud integration", "cloud_logger")
    return {
      add_entry = function(self, entry)
        logger.fallback_log(entry)
      end
    }
  end

  local existingQueue = queues[sessionKey]
  if existingQueue ~= nil then
    return existingQueue
  end

  local scope = "https://www.googleapis.com/auth/logging.write"
  
  local oauth
  local ok, err = pcall(function()
    -- Fix: Pass parameters in the correct order - key first, then scope
    oauth = OAuth(key, scope)
  end)
  
  if not ok or not oauth then
    logger.log_detailed_error(err, "OAuth creation")
    -- Return a fallback logger
    logger.err("Failed to create OAuth object - logging to Kong's logs without Google Cloud integration", "cloud_logger")
    -- Fix: Always return a valid queue object with an add_entry method to prevent nil errors
    return {
      add_entry = function(self, entry)
        logger.fallback_log(entry)
      end
    }
  end

  -- Validate the resource configuration
  if not logging_config.resource or not logging_config.resource.type then
    logger.err("Missing or invalid resource configuration - 'type' field is required", "cloud_logger")
    logger.err("See https://cloud.google.com/logging/docs/reference/v2/rest/v2/MonitoredResource", "cloud_logger")
    return {
      add_entry = function(self, entry)
        logger.fallback_log(entry)
      end
    }
  end
  
  -- Check for valid resource type
  if not VALID_RESOURCE_TYPES[logging_config.resource.type] then
    logger.err("Invalid resource type '" .. logging_config.resource.type .. "'", "cloud_logger")
    logger.err("Common resource types are 'global', 'gce_instance', 'k8s_container'", "cloud_logger")
    logger.err("For this plugin, we recommend using 'global' resource type", "cloud_logger")
    
    -- Force to "global" resource type with appropriate labels
    logger.info("Automatically switching to 'global' resource type", "cloud_logger")
    logging_config.resource = {
      type = "global",
      labels = {
        project_id = key.project_id
      }
    }
  end
  
  -- Validate required resource labels for the given resource type
  if logging_config.resource.type == "global" and (not logging_config.resource.labels or not logging_config.resource.labels.project_id) then
    logger.warn("Resource type 'global' requires 'project_id' label", "cloud_logger")
    
    -- Add project_id if missing
    if not logging_config.resource.labels then
      logging_config.resource.labels = {}
    end
    logging_config.resource.labels.project_id = key.project_id
    logger.info("Automatically adding project_id=" .. key.project_id .. " to resource labels", "cloud_logger")
  end
  
  -- Log the resource configuration
  logger.info("Using resource type: " .. logging_config.resource.type, "cloud_logger")
  if logging_config.resource.labels then
    local labels_str = ""
    for k, v in pairs(logging_config.resource.labels) do
      labels_str = labels_str .. k .. "=" .. v .. " "
    end
    logger.info("Resource labels: " .. labels_str, "cloud_logger")
  else
    logger.warn("No resource labels provided, this may cause logs to be rejected", "cloud_logger")
  end
  
  -- Set up retry options based on configuration
  local retry_opts = {
    max_attempts = retry_options.retry_max_attempts,
    base_delay_ms = retry_options.retry_base_delay,
    max_delay_ms = retry_options.retry_max_delay,
    jitter_factor = 0.2 -- 20% jitter to prevent thundering herd
  }
  
  -- Set up HTTP client options
  local http_opts = {
    timeout = http_options.http_timeout,
    ssl_verify = http_options.http_ssl_verify,
    max_body_log_size = http_options.http_max_body_log_size
  }

  -- Make sure log_id is never nil by using the default from schema if not provided
  local log_id = logging_config.log_id or "kong-plugin-google-cloud-logging"
  local source = logging_config.source or "kong-plugin-google-cloud-logging"
  
  -- Log what we're actually using
  logger.debug("Using log_id: " .. log_id, "cloud_logger")
  logger.debug("Using source: " .. source, "cloud_logger")

  local process = function(entries)
    return _M.send_to_logging(oauth, entries, logging_config.resource, log_id, retry_opts, source, http_opts)
  end

  -- Create a new queue using our custom implementation
  -- Fix: Pass parameters in correct order (ID or identifier, config, flush_callback)
  local q = BatchQueue.new(sessionKey, {
    retry_count = batch_options.retry_count,
    batch_max_size = batch_options.batch_max_size,
    flush_timeout = batch_options.flush_timeout
  }, process)
  
  if not q then
    kong.log.err("Could not create queue")
    -- Fix: Always return a valid queue object with an add_entry method to prevent nil errors
    return {
      add_entry = function(self, entry)
        logger.fallback_log(entry)
      end
    }
  end

  logger.debug("Successfully created batch queue for logging", "cloud_logger")
  queues[sessionKey] = q
  return q
end

return _M