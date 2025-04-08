--- Batch queue implementation for Google Cloud Logging.
-- Provides efficient batching of log entries before sending to Google.
-- @module kong.plugins.google-cloud-logging.batch_queue
local BatchQueue = {}

local kong = kong
local timer_at = ngx.timer.at
local ngx_time = ngx.time
local string_format = string.format
local json_parser = require "kong.plugins.google-cloud-logging.utils.json_parser"

-- Module variables
local queues = {}        -- Table to hold all batch queues
local running = false    -- Whether the background processor is running
local counter = 0        -- Counter for queue IDs

--- Creates a background timer to process queued log entries.
-- @param premature (boolean) Whether the timer is being shutdown
-- @return nil
local function process_queue(premature)
  if premature then
    return
  end
  
  -- Set running flag to ensure only one instance runs
  running = true
  
  local logger = require "kong.plugins.google-cloud-logging.utils.logger"
  logger.debug("Processing batch queues", "BatchQueue")
  
  -- Iterate through all active queues
  for id, queue in pairs(queues) do
    if queue.entries and #queue.entries > 0 then
      -- Check if it's time to flush (max entries reached or timeout)
      local now = ngx_time()
      local time_in_queue = now - queue.last_flush_time
      
      -- Log for debugging
      logger.debug(string_format("Queue %s status: %d entries, %d seconds since last flush",
        id, #queue.entries, time_in_queue), "BatchQueue")
      
      if #queue.entries >= queue.max_batch_size or time_in_queue >= queue.flush_timeout then
        logger.info(string_format("Flushing %d log entries to Google Cloud Logging", #queue.entries), "BatchQueue")
        
        -- Call the queue's flush callback
        local success, err = queue.flush_callback(queue.entries)
        
        -- Update the last flush time regardless of success
        queue.last_flush_time = now
        
        if success then
          -- Clear the entries that were successfully flushed
          queue.entries = {}
          logger.debug("Batch flush successful", "BatchQueue")
        else
          -- Log error but keep entries for retry
          logger.err("Batch flush failed: " .. (err or "Unknown error"), "BatchQueue")
          
          -- Increment retry counter
          queue.retry_count = queue.retry_count + 1
          
          if queue.retry_count >= queue.max_retry_count then
            -- Give up if max retries exceeded
            logger.err(string_format(
              "Giving up on batch after %d retries: %d entries discarded",
              queue.retry_count, #queue.entries), "BatchQueue")
            
            -- Clear the entries to prevent infinite retries
            queue.entries = {}
            queue.retry_count = 0
          end
        end
      end
    end
  end
  
  -- Schedule the next processing run
  local ok, err = timer_at(1, process_queue)
  if not ok then
    logger.err("Failed to create batch queue timer: " .. (err or "unknown"), "BatchQueue")
    running = false
  end
end

--- Creates a new batch queue instance.
-- @param id (string) Optional queue identifier
-- @param config (table) Configuration options for the queue
-- @param flush_callback (function) Function to call when flushing batch
-- @return (table) New batch queue instance
function BatchQueue.new(id, config, flush_callback)
  -- Generate unique ID if not provided
  if not id then
    counter = counter + 1
    id = "queue_" .. counter
  end
  
  -- Initialize config with defaults
  local queue_config = config or {}
  queue_config.max_batch_size = queue_config.max_batch_size or 100
  queue_config.flush_timeout = queue_config.flush_timeout or 30
  queue_config.max_retry_count = queue_config.max_retry_count or 5
  
  -- Create the queue object
  local queue = {
    id = id,
    entries = {},
    max_batch_size = queue_config.max_batch_size,
    flush_timeout = queue_config.flush_timeout,
    max_retry_count = queue_config.max_retry_count,
    retry_count = 0,
    last_flush_time = ngx_time(),
    flush_callback = flush_callback,
    -- Add the methods directly to the queue object
    add_entry = BatchQueue.add_entry,
    flush = BatchQueue.flush,
    cancel = BatchQueue.cancel
  }
  
  -- Store in the queues table
  queues[id] = queue
  
  -- Start the background processor if not already running
  if not running then
    local logger = require "kong.plugins.google-cloud-logging.utils.logger"
    local ok, err = timer_at(1, process_queue)
    if not ok then
      logger.err("Failed to create initial batch queue timer: " .. (err or "unknown"), "BatchQueue")
    else
      logger.info("Started batch queue background processor", "BatchQueue")
    end
  end
  
  return queue
end

--- Adds a log entry to the batch queue.
-- @param self (table) Batch queue instance
-- @param entry (table) Log entry to add to the queue
-- @return (boolean) True on success, false on failure
-- @return (string|nil) Error message on failure
function BatchQueue:add_entry(entry)
  local logger = require "kong.plugins.google-cloud-logging.utils.logger"
  
  if not self or not self.id or not queues[self.id] then
    return false, "Invalid queue"
  end
  
  if not entry then
    return false, "Invalid log entry"
  end
  
  local queue = queues[self.id]
  table.insert(queue.entries, entry)
  
  logger.debug(string_format("Added entry to queue %s (now %d entries)", 
    self.id, #queue.entries), "BatchQueue")
    
  return true
end

--- Forces a queue to flush immediately.
-- @param self (table) Batch queue instance
-- @return (boolean) True on success, false on failure
-- @return (string|nil) Error message on failure
function BatchQueue:flush()
  local logger = require "kong.plugins.google-cloud-logging.utils.logger"
  
  if not self or not self.id or not queues[self.id] then
    return false, "Invalid queue"
  end
  
  local queue = queues[self.id]
  
  if #queue.entries == 0 then
    logger.debug("Queue is empty, nothing to flush", "BatchQueue")
    return true
  end
  
  logger.info(string_format("Manual flush of %d log entries from queue %s", 
    #queue.entries, self.id), "BatchQueue")
  
  local success, err = queue.flush_callback(queue.entries)
  
  -- Update the last flush time regardless of success
  queue.last_flush_time = ngx_time()
  
  if success then
    -- Clear the entries that were successfully flushed
    queue.entries = {}
    logger.debug("Manual flush successful", "BatchQueue")
    return true
  else
    -- Log error but keep entries for retry
    local error_msg = "Manual flush failed: " .. (err or "Unknown error")
    logger.err(error_msg, "BatchQueue")
    return false, error_msg
  end
end

--- Cancels a batch queue and removes it from the system.
-- @param self (table) Batch queue instance
-- @param flush_first (boolean) Whether to flush remaining entries first
-- @return (boolean) True on success, false on failure
-- @return (string|nil) Error message on failure 
function BatchQueue:cancel(flush_first)
  local logger = require "kong.plugins.google-cloud-logging.utils.logger"
  
  if not self or not self.id or not queues[self.id] then
    return false, "Invalid queue"
  end
  
  local queue = queues[self.id]
  
  -- Optionally flush remaining entries
  if flush_first and #queue.entries > 0 then
    logger.info(string_format("Flushing %d remaining entries before canceling queue %s", 
      #queue.entries, self.id), "BatchQueue")
    
    local success, err = queue.flush_callback(queue.entries)
    
    if not success then
      logger.warn(string_format("Failed to flush %d entries during queue cancellation: %s", 
        #queue.entries, (err or "Unknown error")), "BatchQueue")
    end
  end
  
  -- Remove the queue
  queues[self.id] = nil
  logger.info("Canceled batch queue " .. self.id, "BatchQueue")
  
  return true
end

return BatchQueue