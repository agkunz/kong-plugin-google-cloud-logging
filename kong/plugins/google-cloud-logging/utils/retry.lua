--- Retry utility module for Kong Google Cloud Logging plugin.
-- Implements exponential backoff retry logic for failed operations.
-- @module kong.plugins.google-cloud-logging.utils.retry
local logger = require "kong.plugins.google-cloud-logging.utils.logger"

local _M = {}

-- Constants for retry behavior
local DEFAULT_MAX_RETRY_ATTEMPTS = 5
local DEFAULT_BASE_DELAY_MS = 100  -- Start with 100ms delay
local DEFAULT_MAX_DELAY_MS = 30000 -- Cap at 30 seconds
local DEFAULT_JITTER_FACTOR = 0.2  -- 20% random jitter

--- Calculate exponential backoff delay with jitter
-- @param attempt Current retry attempt number (1-based)
-- @param base_delay_ms Base delay in milliseconds
-- @param max_delay_ms Maximum delay in milliseconds
-- @param jitter_factor Amount of randomness to add (0.0-1.0)
-- @return Delay time in milliseconds
function _M.calculate_retry_delay(attempt, base_delay_ms, max_delay_ms, jitter_factor)
  -- Use provided values or defaults
  base_delay_ms = base_delay_ms or DEFAULT_BASE_DELAY_MS
  max_delay_ms = max_delay_ms or DEFAULT_MAX_DELAY_MS
  jitter_factor = jitter_factor or DEFAULT_JITTER_FACTOR
  
  -- Calculate delay with exponential backoff: base * 2^(attempt-1)
  local delay = base_delay_ms * math.pow(2, attempt - 1)
  
  -- Apply max delay cap
  delay = math.min(delay, max_delay_ms)
  
  -- Apply jitter (random variation to prevent coordinated retry spikes)
  if jitter_factor > 0 then
    local jitter_range = delay * jitter_factor
    delay = delay + (math.random() * jitter_range - jitter_range/2)
    -- Ensure delay doesn't go below base_delay_ms due to negative jitter
    delay = math.max(delay, base_delay_ms)
  end
  
  return math.floor(delay)
end

--- Determine if an error should be retried based on its type/code
-- @param err Error object or message
-- @param code HTTP status code if applicable
-- @return boolean indicating if retry is appropriate
function _M.should_retry(err, code)
  -- No retry if no error
  if not err and not code then
    return false
  end
  
  -- Retry based on HTTP status code
  if code then
    -- Retry server errors (5xx) and specific client errors
    if code >= 500 or code == 429 or code == 408 then
      return true
    end
    
    -- Don't retry other client errors (4xx)
    if code >= 400 and code < 500 then
      return false
    end
  end
  
  -- Check error message for network-related issues
  if type(err) == "string" then
    local err_lower = string.lower(err)
    -- Retry on common network/timeout errors
    if err_lower:find("timeout") or 
       err_lower:find("connection") or
       err_lower:find("socket") or
       err_lower:find("network") or
       err_lower:find("temporarily unavailable") or
       err_lower:find("rate limit") or
       err_lower:find("too many requests") then
      return true
    end
  end
  
  -- Default: don't retry unknown errors
  return false
end

--- Sleep for the specified number of milliseconds
-- @param delay_ms Delay in milliseconds
function _M.sleep(delay_ms)
  ngx.sleep(delay_ms / 1000)  -- ngx.sleep takes seconds
end

--- Execute a function with retries using exponential backoff
-- @param func Function to execute
-- @param retry_opts Table of retry options
-- @param ... Arguments to pass to func
-- @return Same returns as func, plus a retry_count value
function _M.with_retries(func, retry_opts, ...)
  local opts = retry_opts or {}
  local max_attempts = opts.max_attempts or DEFAULT_MAX_RETRY_ATTEMPTS
  local base_delay = opts.base_delay_ms or DEFAULT_BASE_DELAY_MS
  local max_delay = opts.max_delay_ms or DEFAULT_MAX_DELAY_MS
  local jitter = opts.jitter_factor or DEFAULT_JITTER_FACTOR
  
  local attempt = 0
  local retry_count = 0
  
  while attempt < max_attempts do
    attempt = attempt + 1
    
    -- Execute the function
    local results = {pcall(func, ...)}
    local success = table.remove(results, 1)
    
    -- On success, return the results plus retry count
    if success then
      table.insert(results, retry_count)
      return unpack(results)
    end
    
    -- Extract error and code from results if available
    local err = results[1]
    local code = results[2]
    
    -- Break if we shouldn't retry this error
    if not _M.should_retry(err, code) then
      -- Re-add retry_count before returning error
      table.insert(results, retry_count)
      return unpack(results)
    end
    
    -- Stop if this was our last attempt
    if attempt >= max_attempts then
      -- Re-add retry_count before returning error
      table.insert(results, retry_count)
      return unpack(results)
    end
    
    -- Calculate delay for this retry
    local delay = _M.calculate_retry_delay(attempt, base_delay, max_delay, jitter)
    
    -- Log the retry using our custom logger
    logger.warn(string.format(
      "Retrying after error (attempt %d/%d, delay %dms): %s",
      attempt, max_attempts, delay, tostring(err)
    ), "retry")
    
    -- Wait before retrying
    _M.sleep(delay)
    
    -- Increment the retry counter
    retry_count = retry_count + 1
  end
  
  -- Shouldn't reach here, but just in case
  return nil, "Exceeded maximum retry attempts", retry_count
end

return _M