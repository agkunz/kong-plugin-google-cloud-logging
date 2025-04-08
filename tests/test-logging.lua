#!/usr/bin/env lua

-- Create mock implementations of OpenResty-specific globals and modules
-- This allows us to run the test outside of OpenResty/Kong environment
if not ngx then
  -- Mock ngx
  ngx = {
    encode_base64 = function(s)
      local mime = require "mime"
      return mime.b64(s)
    end,
    escape_uri = function(s)
      return s:gsub("([^A-Za-z0-9_])", function(c)
        return string.format("%%%02X", string.byte(c))
      end)
    end,
    log = function(level, ...)
      print(...)
    end,
    INFO = "INFO",
    WARN = "WARN",
    ERR = "ERR",
    DEBUG = "DEBUG",
    ctx = {}
  }
  
  -- Mock Kong
  kong = {
    log = {
      err = function(...) print("ERROR:", ...) end,
      warn = function(...) print("WARNING:", ...) end,
      info = function(...) print("INFO:", ...) end,
      debug = function(...) print("DEBUG:", ...) end,
      notice = function(...) print("NOTICE:", ...) end
    }
  }
  
  -- Mock resty.http
  package.loaded["resty.http"] = {
    new = function()
      return {
        request_uri = function(self, url, opts)
          print("HTTP REQUEST to " .. url)
          print("Method: " .. (opts.method or "GET"))
          if opts.body then
            print("Request body: " .. opts.body)
          end
          
          -- Simulate a successful response
          return {
            status = 200,
            body = '{"message": "This is a mock response since we cannot make real HTTP requests in this context"}',
            headers = {
              ["Content-Type"] = "application/json"
            }
          }, nil
        end,
        set_timeout = function() end
      }
    end
  }
  
  -- Mock resty.rsa
  package.loaded["resty.rsa"] = {
    new = function()
      return {
        sign = function() 
          return "MOCK_SIGNATURE", nil
        end
      }
    end,
    PADDING = {
      RSA_PKCS1_PADDING = 1
    }
  }
  
  -- Mock resty.string
  package.loaded["resty.string"] = {
    to_hex = function(s)
      return s
    end
  }
end

-- Now load the original test script code
local json = require "cjson"

-- Simplified version of the diagnostics module for standalone testing
local diagnostics = {}

-- Helper function to validate the Google key
function diagnostics.validate_key(key_file_path)
  local file = io.open(key_file_path, "r")
  if not file then
    print("ERROR: Could not open Google key file: " .. key_file_path)
    return false
  end
  
  local content = file:read("*a")
  file:close()
  
  local ok, key = pcall(json.decode, content)
  if not ok or not key then
    print("ERROR: Failed to parse Google key file as JSON")
    return false
  end
  
  if not key.private_key or not key.client_email or not key.project_id then
    print("ERROR: Google service account key file missing required fields (private_key, client_email, or project_id)")
    return false
  end
  
  print("Service account key validated:")
  print("- Project ID: " .. key.project_id)
  print("- Client Email: " .. key.client_email)
  return true, key
end

-- Simplified validation function
function diagnostics.validate_resource(resource)
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

-- Your plugin configuration (replace with your actual values)
local conf = {
  -- Service account details
  google_key_file = "service-account.json", -- Replace with your key file path
  
  -- Resource configuration
  resource = {
    type = "global", -- Common resource types: global, gce_instance, k8s_container
    labels = {
      project_id = "your-project-id" -- Will be replaced with actual project ID from key file
    }
  },
  
  -- Log configuration
  log_id = "kong-test-logs",
  source = "kong-test-script",
  
  -- Optional: can keep defaults
  retry_max_attempts = 3,
  retry_base_delay = 500,
  retry_max_delay = 5000
}

print("Starting Google Cloud Logging test")
print("NOTE: This script only validates your configuration, it cannot actually send logs")
print("      due to OpenResty dependencies when running outside of Kong/Nginx")

-- First, validate the key file
local key_valid, key = diagnostics.validate_key(conf.google_key_file)
if not key_valid then
  print("Key file validation failed. Please check the path and file contents.")
  os.exit(1)
end

-- Update the project ID from the key file
conf.resource.labels.project_id = key.project_id

-- Then, validate the resource configuration
local resource_valid, resource_error = diagnostics.validate_resource(conf.resource)
if not resource_valid then
  print("Resource configuration error: " .. resource_error)
  os.exit(1)
end

print("\nConfiguration validation successful!")
print("To send real test logs, you need to run this within the Kong environment")
print("For debugging, please check these things:")

print("\n1. In your Kong logs, look for any error messages from 'Google-cloud-logging'")
print("2. Verify that your service account has the right permissions:")
print("   - logging.logEntries.create permission")
print("   - logging.logs.create permission")
print("3. Check your resource configuration matches what Google Cloud expects")
print("4. Make sure network connectivity is available between Kong and Google Cloud")
