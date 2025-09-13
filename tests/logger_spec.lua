-- tests/logger_spec.lua
-- Unit tests for the logging utility

local logger = require "kong.plugins.google-cloud-logging.utils.logger"

describe("Logger Utilities", function()
  local original_kong, original_print
  local captured_logs
  
  before_each(function()
    -- Save originals
    original_kong = _G.kong
    original_print = _G.print
    
    -- Reset captured logs
    captured_logs = {}
    
    -- Mock print to capture fallback logging
    _G.print = function(msg)
      table.insert(captured_logs, {type = "print", message = msg})
    end
    
    -- Mock Kong logging
    _G.kong = {
      log = {
        debug = function(msg) table.insert(captured_logs, {type = "debug", message = msg}) end,
        info = function(msg) table.insert(captured_logs, {type = "info", message = msg}) end,
        notice = function(msg) table.insert(captured_logs, {type = "notice", message = msg}) end,
        warn = function(msg) table.insert(captured_logs, {type = "warn", message = msg}) end,
        err = function(msg) table.insert(captured_logs, {type = "err", message = msg}) end,
        crit = function(msg) table.insert(captured_logs, {type = "crit", message = msg}) end
      }
    }
  end)
  
  after_each(function()
    -- Restore originals
    _G.kong = original_kong
    _G.print = original_print
  end)

  describe("basic logging methods", function()
    it("should log debug messages", function()
      logger.debug("test debug message")
      
      assert.equals(1, #captured_logs)
      assert.equals("debug", captured_logs[1].type)
      assert.equals("test debug message", captured_logs[1].message)
    end)

    it("should log info messages", function()
      logger.info("test info message")
      
      assert.equals(1, #captured_logs)
      assert.equals("info", captured_logs[1].type)
      assert.equals("test info message", captured_logs[1].message)
    end)

    it("should log warning messages", function()
      logger.warn("test warning message")
      
      assert.equals(1, #captured_logs)
      assert.equals("warn", captured_logs[1].type)
      assert.equals("test warning message", captured_logs[1].message)
    end)

    it("should log error messages", function()
      logger.err("test error message")
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.equals("test error message", captured_logs[1].message)
    end)

    it("should log critical messages", function()
      logger.crit("test critical message")
      
      assert.equals(1, #captured_logs)
      assert.equals("crit", captured_logs[1].type)
      assert.equals("test critical message", captured_logs[1].message)
    end)

    it("should log notice messages", function()
      logger.notice("test notice message")
      
      assert.equals(1, #captured_logs)
      assert.equals("notice", captured_logs[1].type)
      assert.equals("test notice message", captured_logs[1].message)
    end)
  end)

  describe("context support", function()
    it("should include context in log messages", function()
      logger.info("test message", "test_context")
      
      assert.equals(1, #captured_logs)
      assert.equals("info", captured_logs[1].type)
      assert.equals("[test_context] test message", captured_logs[1].message)
    end)

    it("should work without context", function()
      logger.warn("message without context")
      
      assert.equals(1, #captured_logs)
      assert.equals("warn", captured_logs[1].type)
      assert.equals("message without context", captured_logs[1].message)
    end)
  end)

  describe("details support", function()
    it("should include details as JSON", function()
      local details = {key = "value", number = 42, bool = true}
      logger.info("test message", "context", details)
      
      assert.equals(1, #captured_logs)
      assert.equals("info", captured_logs[1].type)
      assert.matches("%[context%] test message %- Details:", captured_logs[1].message)
      assert.matches('"key":"value"', captured_logs[1].message)
      assert.matches('"number":42', captured_logs[1].message)
    end)

    it("should work with details but no context", function()
      local details = {status = "error", code = 500}
      logger.err("error occurred", nil, details)
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.matches("error occurred %- Details:", captured_logs[1].message)
      assert.matches('"status":"error"', captured_logs[1].message)
    end)
  end)

  describe("fallback behavior", function()
    it("should fallback to print when Kong is not available", function()
      _G.kong = nil
      
      logger.info("test message")
      
      assert.equals(1, #captured_logs)
      assert.equals("print", captured_logs[1].type)
      assert.equals("INFO: test message", captured_logs[1].message)
    end)

    it("should fallback to print when kong.log is not available", function()
      _G.kong = {}
      
      logger.debug("test debug")
      
      assert.equals(1, #captured_logs)
      assert.equals("print", captured_logs[1].type)
      assert.equals("DEBUG: test debug", captured_logs[1].message)
    end)
  end)

  describe("log_table", function()
    it("should log table as JSON with name", function()
      local test_table = {name = "test", values = {1, 2, 3}}
      logger.log_table("test_data", test_table)
      
      assert.equals(1, #captured_logs)
      assert.equals("debug", captured_logs[1].type)
      assert.matches("test_data:", captured_logs[1].message)
      assert.matches('"name":"test"', captured_logs[1].message)
    end)

    it("should log table with context", function()
      local test_table = {status = "ok"}
      logger.log_table("response", test_table, "api_call")
      
      assert.equals(1, #captured_logs)
      assert.equals("debug", captured_logs[1].type)
      assert.matches("%[api_call%]", captured_logs[1].message)
      assert.matches("response:", captured_logs[1].message)
    end)
  end)

  describe("log_detailed_error", function()
    it("should log structured error objects", function()
      local error_obj = {status = 500, message = "Internal server error"}
      logger.log_detailed_error(error_obj)
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.matches("Error 500: Internal server error", captured_logs[1].message)
    end)

    it("should log structured error with context", function()
      local error_obj = {status = 404, message = "Not found"}
      logger.log_detailed_error(error_obj, "api_request")
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.matches("%[api_request%]", captured_logs[1].message)
      assert.matches("Error 404: Not found", captured_logs[1].message)
    end)

    it("should handle string errors", function()
      logger.log_detailed_error("Simple error message")
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.equals("Simple error message", captured_logs[1].message)
    end)

    it("should handle generic table errors", function()
      local error_obj = {code = "ERR_001", details = "Something went wrong"}
      logger.log_detailed_error(error_obj, "system")
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.matches("%[system%]", captured_logs[1].message)
      assert.matches("Error occurred", captured_logs[1].message)
      assert.matches('"code":"ERR_001"', captured_logs[1].message)
    end)
  end)

  describe("debug_body_info", function()
    it("should log body preview information", function()
      local body = '{"large": "body", "with": "lots", "of": "data", "that": "should", "be": "truncated"}'
      logger.debug_body_info("response", body, "json")
      
      assert.equals(1, #captured_logs)
      assert.equals("debug", captured_logs[1].type)
      assert.matches("Logging response body, parsed as json", captured_logs[1].message)
      assert.matches("Preview:", captured_logs[1].message)
    end)

    it("should handle empty bodies", function()
      logger.debug_body_info("request", "", "empty")
      
      assert.equals(1, #captured_logs)
      assert.equals("debug", captured_logs[1].type)
      assert.matches("%(empty%)", captured_logs[1].message)
    end)

    it("should truncate large bodies", function()
      local large_body = string.rep("x", 200)
      logger.debug_body_info("request", large_body, "text")
      
      assert.equals(1, #captured_logs)
      assert.equals("debug", captured_logs[1].type)
      assert.matches("truncated", captured_logs[1].message)
      assert.matches("total size: 200 bytes", captured_logs[1].message)
    end)

    it("should skip logging when debug is disabled", function()
      _G.kong.log.debug = nil
      
      logger.debug_body_info("request", "test body", "text")
      
      assert.equals(0, #captured_logs)
    end)
  end)

  describe("fallback_log", function()
    it("should extract and log entry information", function()
      local entry = {
        request = {
          requestMethod = "GET",
          requestUrl = "https://api.example.com/test",
          status = 200
        },
        severity = "INFO"
      }
      
      logger.fallback_log(entry)
      
      assert.equals(1, #captured_logs)
      assert.equals("info", captured_logs[1].type)
      assert.matches("%[FALLBACK%]", captured_logs[1].message)
      assert.matches("INFO %- GET", captured_logs[1].message)
      assert.matches("Status: 200", captured_logs[1].message)
    end)

    it("should use appropriate log level for ERROR severity", function()
      local entry = {
        request = {requestMethod = "POST", status = 500},
        severity = "ERROR"
      }
      
      logger.fallback_log(entry)
      
      assert.equals(1, #captured_logs)
      assert.equals("err", captured_logs[1].type)
      assert.matches("ERROR", captured_logs[1].message)
    end)

    it("should use appropriate log level for WARNING severity", function()
      local entry = {
        request = {requestMethod = "PUT", status = 400},
        severity = "WARNING"
      }
      
      logger.fallback_log(entry)
      
      assert.equals(1, #captured_logs)
      assert.equals("warn", captured_logs[1].type)
      assert.matches("WARNING", captured_logs[1].message)
    end)

    it("should handle missing request data gracefully", function()
      local entry = {severity = "INFO"}
      
      logger.fallback_log(entry)
      
      assert.equals(1, #captured_logs)
      assert.equals("info", captured_logs[1].type)
      assert.matches("UNKNOWN unknown_url", captured_logs[1].message)
      assert.matches("Status: 0", captured_logs[1].message)
    end)
  end)
end)
