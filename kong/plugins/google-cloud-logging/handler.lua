local kong = kong
local cloud_logger = require "kong.plugins.google-cloud-logging.cloud_logger"
local logger = require "kong.plugins.google-cloud-logging.utils.logger"

local GoogleLoggingHandler = {}

GoogleLoggingHandler.PRIORITY = 1000
GoogleLoggingHandler.VERSION = "0.1.1"

-- Plugin initialization
function GoogleLoggingHandler:init_worker()
  logger.debug("Initializing google-cloud-logging plugin worker", "init")
  -- No special initialization needed for our custom batch queue
end

-- Access phase handler - capture request body
function GoogleLoggingHandler:access(conf)
  -- Get nested configuration options
  local logging_options = conf.logging_options or {}
  local memory_options = conf.memory_options or {}
  
  -- Capture request body in the access phase if configured
  if logging_options.log_request_body then
    -- Read request body, but don't consume it
    ngx.req.read_body()
    local body = kong.request.get_raw_body()
    
    if body then
      local body_size = #body
      
      -- Check if body exceeds the configured size limit only if limits are enforced
      if memory_options.enforce_body_size_limits and body_size > memory_options.max_request_body_size then
        kong.log.warn(string.format(
          "Request body size (%d bytes) exceeds the configured limit (%d bytes)",
          body_size, memory_options.max_request_body_size
        ))
        
        if memory_options.truncate_large_bodies then
          -- Truncate the body to the configured size limit
          body = string.sub(body, 1, memory_options.max_request_body_size)
          logger.debug("Request body truncated to " .. #body .. " bytes", "access")
        else
          -- Skip logging the body entirely
          logger.debug("Request body will not be logged due to size limit", "access")
          body = nil
        end
      end
      
      -- Store body in context for later use in log phase
      ngx.ctx.request_body = body
      if body then
        logger.debug("Captured request body, length: " .. #body, "access")
      end
    end
  end
end

-- Body filter phase handler - capture response body
function GoogleLoggingHandler:body_filter(conf)
  -- Get nested configuration options
  local logging_options = conf.logging_options or {}
  local memory_options = conf.memory_options or {}
  
  if not logging_options.log_response_body then
    return -- Skip if response body logging is disabled
  end

  -- This is how Kong itself captures response bodies for its plugins
  -- Based on the Kong HTTP log plugin implementation
  local chunk = ngx.arg[1]
  local eof   = ngx.arg[2]

  -- Initialize the buffer if needed
  if not ngx.ctx.google_logging_response_body then
    ngx.ctx.google_logging_response_body = {}
    ngx.ctx.google_logging_response_body_size = 0
  end

  -- Only check size limits if enforcement is enabled
  if memory_options.enforce_body_size_limits then
    -- Check if we're already over the size limit
    if ngx.ctx.google_logging_response_body_size > memory_options.max_response_body_size then
      if eof and not ngx.ctx.google_logging_response_body_size_warning then
        -- Log a warning about the size, but only once per request
        kong.log.warn(string.format(
          "Response body size (%d bytes) exceeds the configured limit (%d bytes)",
          ngx.ctx.google_logging_response_body_size, memory_options.max_response_body_size
        ))
        
        ngx.ctx.google_logging_response_body_size_warning = true
        
        -- Handle truncation if configured
        if memory_options.truncate_large_bodies then
          -- We'll truncate during finalization
          ngx.ctx.google_logging_truncate_response = true
        else
          -- Clear the buffer to skip logging entirely
          ngx.ctx.google_logging_response_body = nil
          ngx.ctx.google_logging_skip_response = true
          logger.debug("Response body will not be logged due to size limit", "body_filter")
        end
      end
      return -- Don't capture any more chunks
    end
  end

  -- Append chunk to buffer with explicit size tracking
  if chunk then
    -- Calculate the new size after adding this chunk
    local new_size = ngx.ctx.google_logging_response_body_size + #chunk
    
    -- Check if this chunk would put us over the limit (only if limits are enforced)
    if memory_options.enforce_body_size_limits and new_size > memory_options.max_response_body_size then
      if memory_options.truncate_large_bodies then
        -- Calculate how much of this chunk we can add without exceeding the limit
        local bytes_remaining = memory_options.max_response_body_size - ngx.ctx.google_logging_response_body_size
        if bytes_remaining > 0 then
          -- Add a truncated version of the chunk
          chunk = string.sub(chunk, 1, bytes_remaining)
          table.insert(ngx.ctx.google_logging_response_body, chunk)
          ngx.ctx.google_logging_response_body_size = memory_options.max_response_body_size
          
          kong.log.warn(string.format(
            "Response body truncated at size limit of %d bytes",
            memory_options.max_response_body_size
          ))
          ngx.ctx.google_logging_truncate_response = true
        end
      else
        -- Skip logging the response body entirely
        ngx.ctx.google_logging_response_body = nil
        ngx.ctx.google_logging_skip_response = true
        kong.log.warn(string.format(
          "Response body size would exceed limit (%d bytes), skipping body logging",
          memory_options.max_response_body_size
        ))
      end
      return
    end
    
    -- Add the chunk (we're either under the size limit or limits are disabled)
    table.insert(ngx.ctx.google_logging_response_body, chunk)
    ngx.ctx.google_logging_response_body_size = new_size
    
    -- Log detailed chunk info
    logger.debug(string.format(
      "Captured chunk #%d, size=%d, total=%d", 
      #ngx.ctx.google_logging_response_body, 
      #chunk, 
      ngx.ctx.google_logging_response_body_size
    ), "body_filter")
  end

  -- If we're finished, concatenate the chunks into a single string
  if eof then
    -- Skip concatenation if we've decided to skip logging
    if ngx.ctx.google_logging_skip_response then
      return
    end
    
    local full_body = table.concat(ngx.ctx.google_logging_response_body)
    
    -- Add truncation indicator if necessary
    if ngx.ctx.google_logging_truncate_response then
      full_body = full_body .. "\n... (truncated)"
    end
    
    ngx.ctx.google_logging_response_body = full_body
    logger.debug("Response capture complete, final size=" .. #full_body, "body_filter")
  end

  -- Do not set ngx.arg[1] at all to avoid changing the response
end

-- Log phase handler - create and send log entry
function GoogleLoggingHandler:log(conf)
  -- Add diagnostic logging at the start of the log phase
  logger.debug("Starting log phase handler", "log")
  
  -- Create log entry using the cloud logger module
  local entry = cloud_logger.create_log_entry(conf)
  if entry then
    logger.debug("Created log entry successfully", "log")
  else
    kong.log.err("Google Cloud Logging Plugin: Failed to create log entry")
    return
  end
  
  -- Get or create a queue for batch processing
  local queue = cloud_logger.get_queue(conf)
  if queue then
    logger.debug("Obtained queue for batch processing", "log")
    -- Fix: Use add_entry instead of add
    queue:add_entry(entry)
    logger.debug("Added entry to processing queue", "log")
  else
    kong.log.err("Google Cloud Logging Plugin: Failed to get batch processing queue")
  end
end

return GoogleLoggingHandler
