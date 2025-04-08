local typedefs = require "kong.db.schema.typedefs"
local json_parser = require "kong.plugins.google-cloud-logging.utils.json_parser"

-- Define valid Google Cloud resource types for dropdown selection
local RESOURCE_TYPES = {
  "global",
  "gce_instance",
  "k8s_container",
  "k8s_cluster",
  "gae_app",
  "cloud_function",
  "cloud_run_revision"
}

-- Helper to validate a Google Cloud service account JSON
local function validate_google_key(key)
  if not key.private_key or not key.client_email or not key.project_id or not key.token_uri then
    kong.log.warn("Google service account key must contain private_key, client_email, project_id, and token_uri")
    return false, "Google service account key must contain private_key, client_email, project_id, and token_uri"
  end
  
  -- Check for common formatting issues with the private key
  if not key.private_key:match("BEGIN.-PRIVATE KEY") then
    -- This isn't a fatal error, as we'll fix it in oauth.lua
    kong.log.notice("Private key doesn't have the standard PEM format, will attempt to fix during runtime")
  end
  
  return true
end

-- Helper to validate a Google Cloud service account JSON file path
local function validate_google_key_file(key_file_path)
  local file, err = io.open(key_file_path, "r")
  if not file then
    kong.log.warn("Google key file not found at " .. key_file_path .. ": " .. (err or "unknown error"))
    -- File doesn't exist, but we'll validate this configuration as it will be handled at runtime
    return false, "Google key file not found at " .. key_file_path .. ": " .. (err or "unknown error")
  end
  
  local content = file:read("*a")
  file:close()
  
  local ok, key = pcall(json_parser.parse_json, content)
  if not ok or not key then
    kong.log.warn(content)
    return false, "Google service account key file is not valid JSON: " .. (err or "unknown error")
  end
  
  return validate_google_key(key)
end

-- Custom validator to ensure the resource configuration is valid
local function validate_resource(resource, config)
  if not resource then
    return true -- Resource is optional
  end
  
  -- Try to get the project_id from the google_key if available
  local project_id
  local auth = config.auth or {}
  if auth.google_key and auth.google_key.project_id then
    project_id = auth.google_key.project_id
  elseif auth.google_key_file and auth.google_key_file ~= "" then
    -- Try to read project_id from the key file
    local file = io.open(auth.google_key_file, "r")
    if file then
      local content = file:read("*a")
      file:close()
      
      local ok, key = pcall(json_parser.parse_json, content)
      if ok and key and key.project_id then
        project_id = key.project_id
      end
    end
  end
  
  -- Auto-populate the project_id for global resource type if it's missing and we have it
  if resource.type == "global" and project_id then
    if not resource.labels then
      resource.labels = {}
    end
    
    -- Only set project_id if it's not already set
    if not resource.labels.project_id then
      resource.labels.project_id = project_id
      kong.log.notice("Google-cloud-logging: Auto-populated project_id=" .. project_id .. " in resource labels")
    end
  end
  
  -- Now validate that required labels are present
  if resource.type == "global" and (not resource.labels or not resource.labels.project_id) then
    return false, "Resource type 'global' requires project_id label"
  end
  
  if resource.type == "gce_instance" and (not resource.labels or 
     not resource.labels.project_id or 
     not resource.labels.instance_id or 
     not resource.labels.zone) then
    return false, "Resource type 'gce_instance' requires project_id, instance_id, and zone labels"
  end
  
  if resource.type == "k8s_container" and (not resource.labels or 
     not resource.labels.project_id or 
     not resource.labels.location or 
     not resource.labels.cluster_name or 
     not resource.labels.namespace_name or 
     not resource.labels.pod_name or 
     not resource.labels.container_name) then
    return false, "Resource type 'k8s_container' requires project_id, location, cluster_name, namespace_name, pod_name, and container_name labels"
  end
  
  -- Add validation for other resource types as needed
  
  return true
end

-- Custom validator to ensure at least one of google_key or google_key_file is set
local function validate_config(config)
  local auth = config.auth or {}
  local has_google_key = auth.google_key ~= nil
  local has_google_key_file = auth.google_key_file ~= nil and auth.google_key_file ~= ""
  
  -- Must have either google_key or google_key_file, but not both
  if not has_google_key and not has_google_key_file then
    return false, "You must provide either google_key or google_key_file"
  end
  
  if has_google_key then
    return validate_google_key(auth.google_key)
  end
  
  if has_google_key_file then
    return validate_google_key_file(auth.google_key_file)
  end
  
  -- Validate resource configuration with access to config
  local logging_config = config.logging_config or {}
  local valid, err = validate_resource(logging_config.resource, config)
  if not valid then
    return false, err
  end
  
  return true
end

return {
  name = "google-cloud-logging",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Authentication section
          { auth = {
              type = "record",
              required = true,
              fields = {
                {
                  google_key = {
                    type = "record",
                    required = false,
                    fields = {
                      { private_key = { type = "string", required = false },},
                      { client_email = { type = "string", required = false },},
                      { project_id = { type = "string", required = false },},
                      { token_uri = { type = "string", required = false, default = "https://oauth2.googleapis.com/token" },},
                    }
                  },
                },
                { 
                  google_key_file = { 
                    type = "string", 
                    required = false,
                    custom_validator = function(key_file_path, auth_table)
                      -- Skip validation if google_key.private_key is provided
                      if auth_table and auth_table.google_key and auth_table.google_key.private_key then
                        return true
                      end
                      
                      -- If google_key is not provided, validate that the file exists
                      if key_file_path and key_file_path ~= "" then
                        return validate_google_key_file(key_file_path)
                      end
                      
                      -- Empty key_file_path is allowed if google_key is provided elsewhere
                      return true
                    end
                  },
                },
              }
            },
          },
          
          -- Logging configuration section
          { logging_config = {
              type = "record",
              required = true,
              fields = {
                { log_id = { 
                    type = "string", 
                    required = false, 
                    default = "kong-plugin-google-cloud-logging"
                }},
                { source = { type = "string", required = false, default = "kong-plugin-google-cloud-logging" },},
                { resource = {
                  type = "record",
                  required = false,
                  fields = {
                    { type = { 
                        type = "string", 
                        required = true, 
                        default = "global",
                        one_of = RESOURCE_TYPES,
                      },
                    },
                    { labels = { 
                        type = "map", 
                        keys = { type = "string" }, 
                        values = { type = "string" },
                      },
                    },
                  }
                }},
              }
            },
          },
          
          -- Batch parameters section
          { batch_options = {
              type = "record",
              required = true,
              fields = {
                { retry_count = { type = "integer", required = false, default = 0 },},
                { flush_timeout = { type = "integer", required = false, default = 2 },},
                { batch_max_size = { type = "integer", required = false, default = 200 },},
              }
            },
          },
          
          -- Logging options section
          { logging_options = {
              type = "record",
              required = true,
              fields = {
                { log_request_headers = { type = "boolean", required = false, default = true },},
                { log_response_headers = { type = "boolean", required = false, default = true },},
                { log_request_body = { type = "boolean", required = false, default = false },},
                { log_response_body = { type = "boolean", required = false, default = false },},
              }
            },
          },
          
          -- Memory optimization options
          { memory_options = {
              type = "record",
              required = true,
              fields = {
                { enforce_body_size_limits = { type = "boolean", required = false, default = true },}, -- Toggle to enable/disable body size limits altogether
                { truncate_large_bodies = { type = "boolean", required = false, default = true },}, -- Whether to truncate bodies exceeding size limit or skip logging them entirely
                { max_request_body_size = { type = "integer", required = false, default = 1048576 },}, -- 1MB default
                { max_response_body_size = { type = "integer", required = false, default = 4194304 },}, -- 4MB default
              }
            },
          },
          
          -- Retry options
          { retry_options = {
              type = "record",
              required = true,
              fields = {
                { retry_max_attempts = { type = "integer", required = false, default = 5 },},
                { retry_base_delay = { type = "number", required = false, default = 200 },}, -- Base delay in ms
                { retry_max_delay = { type = "number", required = false, default = 30000 },}, -- Max delay in ms
              }
            },
          },
          
          -- HTTP client options
          { http_options = {
              type = "record",
              required = true,
              fields = {
                { http_timeout = { type = "integer", required = false, default = 10000 },}, -- HTTP timeout in ms (10 seconds default)
                { http_ssl_verify = { type = "boolean", required = false, default = true },}, -- Whether to verify SSL certificates
                { http_max_body_log_size = { type = "integer", required = false, default = 2000 },}, -- Maximum body size to log in debug messages
              }
            },
          },
        },
        custom_validator = validate_config,
        
        -- Add conditional dependencies between configuration options
        entity_checks = {
          -- Only apply body size limits when enforce_body_size_limits is true
          { conditional = {
              if_field = "memory_options.enforce_body_size_limits", 
              if_match = { eq = false },
              then_field = "memory_options.max_request_body_size",
              then_match = { required = false },
            }
          },
          { conditional = {
              if_field = "memory_options.enforce_body_size_limits", 
              if_match = { eq = false },
              then_field = "memory_options.max_response_body_size",
              then_match = { required = false },
            }
          },
          { conditional = {
              if_field = "memory_options.enforce_body_size_limits", 
              if_match = { eq = false },
              then_field = "memory_options.truncate_large_bodies",
              then_match = { required = false },
            }
          },
          
          -- Only apply retry configuration when retry_count > 0
          { conditional = {
              if_field = "batch_options.retry_count", 
              if_match = { eq = 0 },
              then_field = "retry_options.retry_max_attempts",
              then_match = { required = false },
            }
          },
          { conditional = {
              if_field = "batch_options.retry_count", 
              if_match = { eq = 0 },
              then_field = "retry_options.retry_base_delay",
              then_match = { required = false },
            }
          },
          { conditional = {
              if_field = "batch_options.retry_count", 
              if_match = { eq = 0 },
              then_field = "retry_options.retry_max_delay",
              then_match = { required = false },
            }
          },
          
          -- Only show body logging options when the corresponding setting is enabled
          { conditional = {
              if_field = "logging_options.log_request_body", 
              if_match = { eq = false },
              then_field = "memory_options.max_request_body_size",
              then_match = { required = false },
            }
          },
          { conditional = {
              if_field = "logging_options.log_response_body", 
              if_match = { eq = false },
              then_field = "memory_options.max_response_body_size",
              then_match = { required = false },
            }
          },
        },
      },
    },
  }
}
