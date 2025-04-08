package = "kong-plugin-google-cloud-logging"
version = "0.1.1-1"
local pluginName = package:match("^kong%-plugin%-(.+)$")  -- "google-cloud-logging"
supported_platforms = {"linux", "macosx"}

source = {
  url = "https://github.com/agkunz/kong-plugin-google-cloud-logging",
}

description = {
  summary = "Kong plugin that sends log information to Google Cloud Logging.",
  homepage = "https://github.com/agkunz/kong-plugin-google-cloud-logging",
  license = "MIT"
}

dependencies = {
  "lua-cjson",
  "mimetypes",
  "lua >= 5.1",
  "lua-resty-http",
  "lua-resty-jwt",
  "lua-resty-timer",
  "lua-resty-openssl >= 0.8.0",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
    ["kong.plugins."..pluginName..".batch_queue"] = "kong/plugins/"..pluginName.."/batch_queue.lua",
    ["kong.plugins."..pluginName..".cloud_logger"] = "kong/plugins/"..pluginName.."/cloud_logger.lua",
    ["kong.plugins."..pluginName..".utils.json_parser"] = "kong/plugins/"..pluginName.."/utils/json_parser.lua",
    ["kong.plugins."..pluginName..".utils.logger"] = "kong/plugins/"..pluginName.."/utils/logger.lua",
    ["kong.plugins."..pluginName..".utils.retry"] = "kong/plugins/"..pluginName.."/utils/retry.lua",
    ["kong.plugins."..pluginName..".utils.diagnostics"] = "kong/plugins/"..pluginName.."/utils/diagnostics.lua",
    ["kong.plugins."..pluginName..".lib.http"] = "kong/plugins/"..pluginName.."/lib/http.lua",
    ["kong.plugins."..pluginName..".lib.oauth"] = "kong/plugins/"..pluginName.."/lib/oauth.lua",
  }
}
