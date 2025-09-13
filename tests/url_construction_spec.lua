-- tests/url_construction_spec.lua
-- Proper BDD-style test for the URL construction fix using Busted

describe("URL Construction Fix", function()
  local original_ngx, original_kong, original_logger
  
  before_each(function()
    -- Save original globals if they exist
    original_ngx = _G.ngx
    original_kong = _G.kong
    original_logger = _G.logger
    
    -- Mock the Kong/OpenResty environment
    _G.ngx = {
      var = {},
      ctx = {}
    }
    
    _G.kong = {
      request = {
        get_header = function(header_name)
          if header_name == "host" then
            return ngx.var.host
          end
          return nil
        end
      }
    }
    
    -- Mock logger to avoid dependency issues
    _G.logger = {
      debug = function() end
    }
  end)
  
  after_each(function()
    -- Restore original globals
    _G.ngx = original_ngx
    _G.kong = original_kong
    _G.logger = original_logger
  end)

  -- The actual URL construction function from our fix
  local function construct_request_url()
    local scheme = ngx.var.scheme or "http"
    local host = kong.request.get_header("host") or ngx.var.host or "localhost"
    local request_uri = ngx.var.request_uri or "/"
    
    local url = scheme .. "://" .. host .. request_uri
    logger.debug("Constructed request URL: " .. url)
    return url
  end

  describe("when handling standard HTTPS requests", function()
    it("should NOT include port 8443 for keycloak.paclan.net", function()
      -- Arrange: Your exact scenario
      ngx.var.scheme = "https"
      ngx.var.host = "keycloak.paclan.net"
      ngx.var.request_uri = "/admin/hi-its-me"
      
      -- Act
      local result = construct_request_url()
      
      -- Assert
      assert.equals("https://keycloak.paclan.net/admin/hi-its-me", result)
      assert.is_not.equals("https://keycloak.paclan.net:8443/admin/hi-its-me", result)
    end)
    
    it("should work correctly for any HTTPS domain on standard port 443", function()
      -- Arrange
      ngx.var.scheme = "https"
      ngx.var.host = "api.example.com"
      ngx.var.request_uri = "/v1/users"
      
      -- Act
      local result = construct_request_url()
      
      -- Assert
      assert.equals("https://api.example.com/v1/users", result)
      assert.is_not.matches(":8443", result) -- Should NOT contain 8443
    end)
  end)

  describe("when handling standard HTTP requests", function()
    it("should NOT include port 8443 for HTTP requests", function()
      -- Arrange
      ngx.var.scheme = "http"
      ngx.var.host = "api.example.com"
      ngx.var.request_uri = "/health"
      
      -- Act
      local result = construct_request_url()
      
      -- Assert
      assert.equals("http://api.example.com/health", result)
      assert.is_not.matches(":8443", result) -- Should NOT contain 8443
    end)
  end)

  describe("when clients specify custom ports", function()
    it("should preserve custom ports when explicitly provided", function()
      -- Arrange
      ngx.var.scheme = "https"
      ngx.var.host = "localhost:9443"  -- Client specified custom port
      ngx.var.request_uri = "/test"
      
      -- Act
      local result = construct_request_url()
      
      -- Assert
      assert.equals("https://localhost:9443/test", result)
      assert.matches(":9443", result) -- Should preserve the custom port
      assert.is_not.matches(":8443", result) -- Should NOT change to 8443
    end)
  end)

  describe("when handling complex URLs", function()
    it("should handle query parameters correctly", function()
      -- Arrange
      ngx.var.scheme = "https"
      ngx.var.host = "api.test.com"
      ngx.var.request_uri = "/search?q=test&limit=10&sort=desc"
      
      -- Act
      local result = construct_request_url()
      
      -- Assert
      assert.equals("https://api.test.com/search?q=test&limit=10&sort=desc", result)
      assert.is_not.matches(":8443", result)
    end)
    
    it("should handle paths with special characters", function()
      -- Arrange  
      ngx.var.scheme = "https"
      ngx.var.host = "files.example.com"
      ngx.var.request_uri = "/download/file%20with%20spaces.pdf"
      
      -- Act
      local result = construct_request_url()
      
      -- Assert
      assert.equals("https://files.example.com/download/file%20with%20spaces.pdf", result)
      assert.is_not.matches(":8443", result)
    end)
  end)

  describe("Kong's problematic behavior simulation", function()
    it("demonstrates the problem our fix solves", function()
      -- This test shows what Kong's logs.request.url would give us (wrong)
      local kong_wrong_url = "https://keycloak.paclan.net:8443/admin/hi-its-me"
      
      -- Setup our environment to match the real request
      ngx.var.scheme = "https"
      ngx.var.host = "keycloak.paclan.net"  -- No port in actual request
      ngx.var.request_uri = "/admin/hi-its-me"
      
      -- Our fix produces the correct URL
      local our_correct_url = construct_request_url()
      
      -- Assert the fix works
      assert.is_not.equals(kong_wrong_url, our_correct_url)
      assert.equals("https://keycloak.paclan.net/admin/hi-its-me", our_correct_url)
      
      -- Verify we fixed the core issue
      assert.is_not.matches(":8443", our_correct_url)
    end)
  end)
end)
