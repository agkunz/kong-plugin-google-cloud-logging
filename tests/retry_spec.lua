-- tests/retry_spec.lua
-- Unit tests for retry logic utilities

local retry = require "kong.plugins.google-cloud-logging.utils.retry"

describe("Retry Utilities", function()
  local original_ngx, original_math_random
  local sleep_calls
  
  before_each(function()
    -- Save originals
    original_ngx = _G.ngx
    original_math_random = math.random
    
    -- Track sleep calls
    sleep_calls = {}
    
    -- Mock ngx.sleep
    _G.ngx = {
      sleep = function(seconds)
        table.insert(sleep_calls, seconds * 1000) -- Convert back to ms for tracking
      end
    }
    
    -- Mock math.random for predictable jitter testing
    math.random = function()
      return 0.5 -- Always return 0.5 for predictable results
    end
  end)
  
  after_each(function()
    -- Restore originals
    _G.ngx = original_ngx
    math.random = original_math_random
  end)

  describe("calculate_retry_delay", function()
    it("should calculate exponential backoff correctly", function()
      -- Test exponential progression: 100ms, 200ms, 400ms, 800ms
      assert.equals(100, retry.calculate_retry_delay(1, 100, 30000, 0)) -- No jitter
      assert.equals(200, retry.calculate_retry_delay(2, 100, 30000, 0))
      assert.equals(400, retry.calculate_retry_delay(3, 100, 30000, 0))
      assert.equals(800, retry.calculate_retry_delay(4, 100, 30000, 0))
    end)

    it("should respect maximum delay cap", function()
      -- Large attempt should be capped at max_delay
      local delay = retry.calculate_retry_delay(10, 100, 1000, 0)
      assert.equals(1000, delay)
    end)

    it("should use default values when not provided", function()
      local delay = retry.calculate_retry_delay(1)
      assert.equals(100, delay) -- Default base delay
    end)

    it("should apply jitter correctly", function()
      -- With math.random() returning 0.5, jitter should be predictable
      local base_delay = 100
      local jitter_factor = 0.2
      local expected_jitter = 0 -- (0.5 * 20 - 10) = 0 for attempt 1
      local delay = retry.calculate_retry_delay(1, base_delay, 30000, jitter_factor)
      
      assert.equals(100, delay) -- Should be base delay + 0 jitter
    end)

    it("should not go below base delay due to negative jitter", function()
      -- Override math.random to return 0 (maximum negative jitter)
      math.random = function() return 0 end
      
      local delay = retry.calculate_retry_delay(1, 100, 30000, 0.5)
      assert.is_true(delay >= 100) -- Should not go below base delay
    end)
  end)

  describe("should_retry", function()
    it("should retry on 5xx server errors", function()
      assert.is_true(retry.should_retry("Server error", 500))
      assert.is_true(retry.should_retry("Bad gateway", 502))
      assert.is_true(retry.should_retry("Service unavailable", 503))
    end)

    it("should retry on rate limit errors", function()
      assert.is_true(retry.should_retry("Too many requests", 429))
    end)

    it("should retry on timeout errors", function()
      assert.is_true(retry.should_retry("Request timeout", 408))
    end)

    it("should not retry on 4xx client errors (except specific ones)", function()
      assert.is_false(retry.should_retry("Bad request", 400))
      assert.is_false(retry.should_retry("Unauthorized", 401))
      assert.is_false(retry.should_retry("Forbidden", 403))
      assert.is_false(retry.should_retry("Not found", 404))
    end)

    it("should retry on network-related error messages", function()
      assert.is_true(retry.should_retry("Connection timeout"))
      assert.is_true(retry.should_retry("Socket error"))
      assert.is_true(retry.should_retry("Network unreachable"))
      assert.is_true(retry.should_retry("Temporarily unavailable"))
      assert.is_true(retry.should_retry("Rate limit exceeded"))
    end)

    it("should not retry on unknown errors", function()
      assert.is_false(retry.should_retry("Unknown error"))
      assert.is_false(retry.should_retry("Invalid data format"))
    end)

    it("should not retry when no error is provided", function()
      assert.is_false(retry.should_retry(nil, nil))
      assert.is_false(retry.should_retry(nil, 200))
    end)
  end)

  describe("sleep", function()
    it("should convert milliseconds to seconds for ngx.sleep", function()
      retry.sleep(1000) -- 1000ms = 1 second
      
      assert.equals(1, #sleep_calls)
      assert.equals(1000, sleep_calls[1]) -- We track in ms for easier testing
    end)

    it("should handle fractional delays", function()
      retry.sleep(500) -- 500ms = 0.5 seconds
      
      assert.equals(1, #sleep_calls)
      assert.equals(500, sleep_calls[1])
    end)
  end)

  describe("with_retries", function()
    it("should return success on first try", function()
      local success_func = function()
        return "success", "extra_value"
      end
      
      local result1, result2, retry_count = retry.with_retries(success_func)
      
      assert.equals("success", result1)
      assert.equals("extra_value", result2)
      assert.equals(0, retry_count) -- No retries needed
      assert.equals(0, #sleep_calls) -- No sleep calls
    end)

    it("should retry on retryable errors", function()
      local attempt_count = 0
      local failing_func = function()
        attempt_count = attempt_count + 1
        if attempt_count < 3 then
          error("Connection timeout") -- Retryable error
        end
        return "success_after_retries"
      end
      
      local result, retry_count = retry.with_retries(failing_func, {max_attempts = 5})
      
      assert.equals("success_after_retries", result)
      assert.equals(2, retry_count) -- Retried 2 times
      assert.equals(2, #sleep_calls) -- Should have slept 2 times
    end)

    it("should not retry on non-retryable errors", function()
      local failing_func = function()
        return nil, "Bad request", 400 -- Non-retryable
      end
      
      local result, err, code, retry_count = retry.with_retries(failing_func)
      
      assert.is_nil(result)
      assert.equals("Bad request", err)
      assert.equals(400, code)
      assert.equals(0, retry_count) -- No retries attempted
      assert.equals(0, #sleep_calls) -- No sleep calls
    end)

    it("should respect max_attempts limit", function()
      local failing_func = function()
        error("Connection timeout") -- Always retryable
      end
      
      local result, retry_count = retry.with_retries(failing_func, {max_attempts = 3})
      
      assert.matches("Connection timeout", result) -- Error message is returned as first value
      assert.equals(2, retry_count) -- Retried 2 times (3 total attempts)
      assert.equals(2, #sleep_calls) -- Should have slept 2 times
    end)

    it("should use custom retry options", function()
      local failing_func = function()
        error("Connection timeout") -- Retryable
      end
      
      local opts = {
        max_attempts = 2,
        base_delay_ms = 50,
        max_delay_ms = 1000,
        jitter_factor = 0
      }
      
      retry.with_retries(failing_func, opts)
      
      assert.equals(1, #sleep_calls) -- 1 retry = 1 sleep
      assert.equals(50, sleep_calls[1]) -- Should use custom base delay
    end)

    it("should handle functions with multiple return values", function()
      local multi_return_func = function()
        return "value1", "value2", "value3"
      end
      
      local v1, v2, v3, retry_count = retry.with_retries(multi_return_func)
      
      assert.equals("value1", v1)
      assert.equals("value2", v2)
      assert.equals("value3", v3)
      assert.equals(0, retry_count)
    end)

    it("should handle functions with arguments", function()
      local echo_func = function(a, b, c)
        return a .. b .. c
      end
      
      local result, retry_count = retry.with_retries(echo_func, nil, "hello", " ", "world")
      
      assert.equals("hello world", result)
      assert.equals(0, retry_count)
    end)

    it("should implement exponential backoff delays", function()
      local attempt_count = 0
      local failing_func = function()
        attempt_count = attempt_count + 1
        if attempt_count <= 3 then
          error("Connection timeout") -- Always fail first 3 attempts, retryable
        end
        return "success"
      end
      
      local opts = {
        max_attempts = 5,
        base_delay_ms = 100,
        jitter_factor = 0 -- No jitter for predictable testing
      }
      
      retry.with_retries(failing_func, opts)
      
      assert.equals(3, #sleep_calls)
      assert.equals(100, sleep_calls[1]) -- First retry: 100ms
      assert.equals(200, sleep_calls[2]) -- Second retry: 200ms  
      assert.equals(400, sleep_calls[3]) -- Third retry: 400ms
    end)

    it("should handle nil return values correctly", function()
      local nil_func = function()
        return nil
      end
      
      local retry_count = retry.with_retries(nil_func)
      
      assert.equals(0, retry_count) -- Function succeeded, returns only retry count
    end)

    it("should preserve error information across retries", function()
      local attempt_count = 0
      local failing_func = function()
        attempt_count = attempt_count + 1
        if attempt_count <= 1 then  -- Fail only on first attempt
          error("Timeout error") -- Retryable via error()
        end
        return "success", "extra_data"
      end
      
      local result, extra, retry_count = retry.with_retries(failing_func, {max_attempts = 3})
      
      assert.equals("success", result)
      assert.equals("extra_data", extra)
      assert.equals(1, retry_count) -- One retry before success
    end)
  end)
end)
