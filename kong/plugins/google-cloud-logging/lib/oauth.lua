--- OAuth authentication module for Google Cloud APIs.
-- Manages OAuth token acquisition and refresh for Google Cloud services.
-- @module kong.plugins.google-cloud-logging.lib.oauth
local http = require "resty.http"
local json_parser = require "kong.plugins.google-cloud-logging.utils.json_parser"
local logger = require "kong.plugins.google-cloud-logging.utils.logger"

-- Load JWT libraries
pcall(require, "lua_pack")
pcall(require, "utils") -- For better error reporting in some cases
local cjson = require "cjson"
local digest = require "resty.openssl.digest"
local hmac = require "resty.openssl.hmac"
local pkey = require "resty.openssl.pkey"
local x509 = require "resty.openssl.x509"
local base64 = require "ngx.base64"

local ngx_now = ngx.now
local ngx_update_time = ngx.update_time
local ngx_time = ngx.time
local table_concat = table.concat
local string_format = string.format
local string_sub = string.sub

-- Google OAuth token endpoint
local OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"

-- Default OAuth configuration
local DEFAULT_TIMEOUT = 10000  -- 10 seconds
local DEFAULT_SSL_VERIFY = true

--- OAuth client implementation for Google service account authentication.
-- @type GoogleOAuthClient
local GoogleOAuthClient = {}

--- Create a new GoogleOAuthClient instance.
-- @param credentials (table) Service account credentials
-- @param scope (string) OAuth scope for the API
-- @param options (table) Configuration options
-- @return (table) New GoogleOAuthClient instance
function GoogleOAuthClient:new(credentials, scope, options)
  if not credentials then
    return nil, "No credentials provided"
  end
  
  if not scope then
    return nil, "No scope provided"
  end
  
  local instance = {
    credentials = credentials,
    scope = scope,
    token = nil,
    token_expiry = 0,
    options = options or {}
  }
  
  -- Set defaults for options if not provided
  instance.options.timeout = instance.options.timeout or DEFAULT_TIMEOUT
  instance.options.ssl_verify = instance.options.ssl_verify
  if instance.options.ssl_verify == nil then
    instance.options.ssl_verify = DEFAULT_SSL_VERIFY
  end
  
  -- Save some service account info for convenience and validation
  instance.email = credentials.client_email
  instance.project_id = credentials.project_id
  
  -- Validate service account credentials format
  if not instance.email or not instance.project_id then
    return nil, "Invalid service account format - missing client_email or project_id"
  end
  
  -- Log credentials details (without sensitive parts)
  logger.debug("Created OAuth client for service account: " .. instance.email, "OAuth")
  
  setmetatable(instance, { __index = self })
  return instance
end

--- Generate a JWT assertion for OAuth token requests.
-- @param self (table) GoogleOAuthClient instance
-- @return (string) JWT assertion
-- @return (string|nil) Error message on failure
local function generate_jwt_assertion(self)
  local ngx_mime = require "ngx.base64"
  local openssl_digest = require "resty.openssl.digest"
  local openssl_pkey = require "resty.openssl.pkey"
  
  local current_time = ngx.time()
  local expiry_time = current_time + 3600 -- 1 hour from now
  
  -- Create JWT header
  local header = {
    alg = "RS256",
    typ = "JWT"
  }
  
  -- Create JWT claim set
  local claim_set = {
    iss = self.email,
    scope = self.scope,
    aud = OAUTH_TOKEN_URL,
    exp = expiry_time,
    iat = current_time
  }
  
  -- Encode header and claim set to base64url
  local header_json = json_parser.encode_json(header)
  local claim_set_json = json_parser.encode_json(claim_set)
  
  if not header_json or not claim_set_json then
    return nil, "Failed to encode JWT header or claim set"
  end
  
  local encoded_header = ngx_mime.encode_base64url(header_json)
  local encoded_claim_set = ngx_mime.encode_base64url(claim_set_json)
  
  -- Create signature input
  local signature_input = encoded_header .. "." .. encoded_claim_set
  
  -- Load private key
  local private_key_str = self.credentials.private_key
  if not private_key_str then
    return nil, "Service account missing private_key"
  end
  
  -- Enhanced logging for debugging
  logger.debug("Private key length: " .. #private_key_str, "JWT")
  
  -- Replace escaped newlines with actual newlines
  if private_key_str:match("\\n") then
    logger.debug("Found \\n in private key, replacing with actual newlines", "JWT")
    private_key_str = private_key_str:gsub("\\n", "\n")
  end
  
  -- Remove surrounding quotes if present
  if private_key_str:match("^\"") and private_key_str:match("\"$") then
    logger.debug("Found quotes enclosing private key, removing them", "JWT")
    private_key_str = private_key_str:gsub("^\"|\"$", "")
  end

  if not private_key_str:match("^%-%-%-%-%-BEGIN") then
    logger.debug("Adding PEM header/footer to private key", "JWT")
    private_key_str = "-----BEGIN PRIVATE KEY-----\n" .. private_key_str .. "\n-----END PRIVATE KEY-----"
  end

  -- Use pcall to safely try loading the key
  local ok, pkey_or_err = pcall(function()
    return openssl_pkey.new(private_key_str)
  end)
  
  if not ok then
    logger.err("Failed to load private key: " .. tostring(pkey_or_err), "JWT")
    return nil, "Failed to load private key: " .. tostring(pkey_or_err)
  end
  
  local pkey = pkey_or_err
  if not pkey then
    logger.err("Failed to load private key: unknown error", "JWT")
    return nil, "Failed to load private key: unknown error"
  end
  
  -- Sign the JWT
  local digest = openssl_digest.new("sha256")
  digest:update(signature_input)
  
  local signature, sign_err = pkey:sign(digest)
  if not signature then
    logger.err("Failed to sign JWT: " .. (sign_err or "unknown error"), "JWT")
    return nil, "Failed to sign JWT: " .. (sign_err or "unknown error")
  end
  
  -- Encode the signature to base64url
  local encoded_signature = ngx_mime.encode_base64url(signature)
  
  -- Combine to form the complete JWT
  local jwt = signature_input .. "." .. encoded_signature
  logger.debug("Successfully generated JWT", "JWT")
  
  return jwt
end

--- Requests a new OAuth access token from Google.
-- @param self (table) GoogleOAuthClient instance
-- @return (string) Access token
-- @return (string|nil) Error message on failure
local function request_token(self)
  logger.debug("Requesting new OAuth token for " .. self.email, "OAuth")
  
  -- Generate the JWT assertion
  local jwt, jwt_err = generate_jwt_assertion(self)
  if not jwt then
    return nil, "Failed to generate JWT: " .. (jwt_err or "unknown error")
  end
  
  -- Create HTTP client
  local httpc = http.new()
  httpc:set_timeout(self.options.timeout)
  
  -- Prepare request body
  local body = {
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion = jwt
  }
  
  -- Encode body as application/x-www-form-urlencoded
  local body_parts = {}
  for k, v in pairs(body) do
    table.insert(body_parts, k .. "=" .. ngx.escape_uri(v))
  end
  local encoded_body = table.concat(body_parts, "&")
  
  -- Make the token request
  local res, err = httpc:request_uri(OAUTH_TOKEN_URL, {
    method = "POST",
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded"
    },
    body = encoded_body,
    ssl_verify = self.options.ssl_verify
  })
  
  if not res then
    return nil, "OAuth token request failed: " .. (err or "unknown error")
  end
  
  if res.status ~= 200 then
    return nil, "OAuth token request failed with status " .. res.status .. ": " .. res.body
  end
  
  -- Parse the response
  local response = json_parser.parse_json(res.body)
  if not response or not response.access_token then
    return nil, "Invalid OAuth response: missing access_token"
  end
  
  -- Calculate token expiry time (conservatively)
  local expires_in = response.expires_in or 3600
  local expiry_time = ngx.time() + expires_in - 300  -- 5 minutes safety margin
  
  logger.debug("Successfully obtained OAuth token, expires in " .. expires_in .. " seconds", "OAuth")
  
  return response.access_token, nil, expiry_time
end

--- Gets a valid OAuth access token, requesting a new one if necessary.
-- @return (string) Access token
-- @return (string|nil) Error message on failure
function GoogleOAuthClient:get_access_token()
  local current_time = ngx.time()
  
  -- Check if we have a valid token
  if self.token and current_time < self.token_expiry then
    logger.debug("Using cached OAuth token", "OAuth")
    return self.token
  end
  
  -- Request a new token
  logger.debug("Cached token expired or not available, requesting new token", "OAuth")
  local token, err, expiry = request_token(self)
  
  if not token then
    return nil, err
  end
  
  -- Cache the token and expiry
  self.token = token
  self.token_expiry = expiry or (current_time + 3300)  -- Default 55 minutes
  
  return token
end

--- Gets the project ID from the service account credentials.
-- @return (string) Project ID
function GoogleOAuthClient:get_project_id()
  return self.project_id
end

--- Factory function to create a new GoogleOAuthClient.
-- @param credentials (table) Service account credentials
-- @param scope (string) OAuth scope for the API
-- @param options (table) Configuration options
-- @return (table) New GoogleOAuthClient instance
-- @return (string|nil) Error message on failure
return function(credentials, scope, options)
  return GoogleOAuthClient:new(credentials, scope, options)
end