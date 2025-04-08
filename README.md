# Kong Google Logging Plugin

A Kong plugin that exports request and response data from your API gateway to Google Cloud Logging with advanced configuration options, comprehensive data capture, intelligent batching, and robust error handling.

## Features

- **Comprehensive Request/Response Logging**: Capture full details including headers, bodies, latency metrics and more
- **Intelligent Body Handling**: Configurable size limits with truncation options to prevent memory issues
- **Smart Batching**: Efficiently send logs in batches with configurable parameters
- **Robust Retry Mechanism**: Configurable retry logic with exponential backoff and jitter
- **Fallback Logging**: Graceful degradation to Kong's native logging when Google Cloud is unavailable
- **Secure Authentication**: Strong support for Google service account authentication
- **Memory Optimized**: Careful memory management for high-throughput environments
- **Well-Structured Logs**: Properly organized log entries that work seamlessly with Google Cloud Logging 

## Logged Data

The plugin captures and exports the following data to Google Cloud Logging:

- Service name and details
- Route information
- Consumer identity
- Request URI and query parameters
- Complete latency breakdown (request, gateway, proxy)
- Request and response headers (configurable)
- Request and response bodies (configurable with size limits)
- Standard Google Cloud Logging httpRequest format
- Custom severity levels based on response status codes

All logs are labeled with a configurable source value (default: `"source": "kong-plugin-google-cloud-logging"`) for easy filtering in Google Cloud Logging.

## Installation

```bash
git clone https://github.com/agkunz/kong-plugin-google-cloud-logging
cd kong-plugin-google-cloud-logging
luarocks make
```

Then add the plugin to your Kong configuration:

```
plugins = bundled,google-cloud-logging
```

## Configuration Parameters

| Parameter               | Required | Type           | Default                    | Description |
|-------------------------|----------|----------------|----------------------------|-------------|
| **Authentication Options** |        |                |                            | |
| `google_key`            | False    | Record         | -                          | Service account credentials as a record (not recommended for production) |
| `google_key_file`       | False    | String         | -                          | Path to the service account JSON file (preferred for security) |
| **Logging Configuration** |        |                |                            | |
| `log_id`                | False    | String         | kong-plugin-google-cloud-logging       | The log ID to use in Google Cloud Logging |
| `source`                | False    | String         | kong-plugin-google-cloud-logging       | The source label for log entries in Google Cloud Logging |
| `resource`              | False    | Record         | -                          | The monitored resource definition for Google Cloud |
| `log_request_headers`   | False    | Boolean        | true                       | Whether to include request headers in logs |
| `log_response_headers`  | False    | Boolean        | true                       | Whether to include response headers in logs |
| `log_request_body`      | False    | Boolean        | false                      | Whether to capture and log request bodies |
| `log_response_body`     | False    | Boolean        | false                      | Whether to capture and log response bodies |
| **Memory Optimization** |        |                |                            | |
| `max_request_body_size` | False    | Integer        | 1048576 (1MB)              | Maximum size of request body to log (in bytes) |
| `max_response_body_size`| False    | Integer        | 4194304 (4MB)              | Maximum size of response body to log (in bytes) |
| `truncate_large_bodies` | False    | Boolean        | true                       | Whether to truncate bodies exceeding size limit (false = skip logging entirely) |
| `enforce_body_size_limits` | False | Boolean        | true                       | Master toggle to enable/disable all body size limits |
| **Batching Parameters** |        |                |                            | |
| `retry_count`           | False    | Integer        | 0                          | Number of times to retry processing after a failure |
| `flush_timeout`         | False    | Integer        | 2                          | Seconds of inactivity before flushing the batch queue |
| `batch_max_size`        | False    | Integer        | 200                        | Maximum number of log entries in a batch before sending |
| **Retry Options**       |        |                |                            | |
| `retry_max_attempts`    | False    | Integer        | 5                          | Maximum number of retry attempts for failed API calls |
| `retry_base_delay`      | False    | Number         | 200                        | Base delay between retries in milliseconds |
| `retry_max_delay`       | False    | Number         | 30000                      | Maximum delay between retries in milliseconds |
| **HTTP Client Options** |        |                |                            | |
| `http_timeout`          | False    | Integer        | 10000                      | HTTP timeout in milliseconds (10 seconds default) |
| `http_ssl_verify`       | False    | Boolean        | true                       | Whether to verify SSL certificates when connecting to Google APIs |
| `http_max_body_log_size`| False    | Integer        | 2000                       | Maximum body size to log in debug messages (bytes)

### Parameter Details

#### Authentication

You must provide **either** `google_key` or `google_key_file` (but not both):

* **google_key**: The service account credentials as a record with:
  - `private_key`: The private key for the service account
  - `client_email`: The client email for the service account
  - `project_id`: The Google Cloud project ID
  - `token_uri`: The token URI (defaults to "https://oauth2.googleapis.com/token")

* **google_key_file**: Path to a service account JSON file that contains the above fields

The service account must have the `https://www.googleapis.com/auth/logging.write` scope.

#### Resource Configuration

The `resource` field should contain:
- `type`: The resource type (e.g., "global", "gce_instance")
- `labels`: A map of key-value pairs for resource labels

See [Google's documentation](https://cloud.google.com/logging/docs/reference/v2/rest/v2/MonitoredResource) for supported resource types and required labels.

#### Body Logging

Request and response body logging is disabled by default to conserve memory. When enabled:

- Bodies are captured only up to the configured size limits (when `enforce_body_size_limits` is true)
- Bodies larger than the limits are either truncated or skipped entirely based on `truncate_large_bodies`
- For JSON bodies, proper parsing and formatting is maintained in logs
- Set `enforce_body_size_limits` to false to log entire bodies regardless of size (use with caution)

#### Batch Processing

The plugin uses an intelligent batching system to minimize API calls to Google Cloud:

- Logs are collected into batches until `batch_max_size` is reached or `flush_timeout` seconds of inactivity occur
- Failed batches can be retried based on `retry_count`
- Individual API calls have their own retry logic, configurable via `retry_max_attempts`, `retry_base_delay`, and `retry_max_delay`

### HTTP Client Options

The plugin uses HTTP client options to control how it communicates with Google Cloud Logging:

- `http_timeout`: Controls how long the plugin will wait for a response from Google's API before timing out. Increase this value in environments with slower network connections or when experiencing timeout issues.

- `http_ssl_verify`: Controls whether SSL certificates are verified when connecting to Google APIs. While disabling this can help troubleshoot connection issues, it should be enabled in production environments for security.

- `http_max_body_log_size`: Limits the size of request/response bodies included in debug logs. This is useful for troubleshooting without filling logs with large payloads. This only affects debug logs, not the actual data sent to Google Cloud Logging.

## Example Configuration

```lua
-- Basic configuration
config = {
  google_key_file = "/etc/kong/gcp-service-account.json",
  log_id = "kong-api-gateway",
  resource = {
    type = "global",
    labels = {
      project_id = "my-project",
      namespace = "production"
    }
  }
}

-- Advanced configuration with body logging
config = {
  google_key_file = "/etc/kong/gcp-service-account.json",
  log_id = "kong-api-gateway-detailed",
  resource = {
    type = "k8s_container",
    labels = {
      project_id = "my-project",
      cluster_name = "my-cluster",
      namespace_name = "kong",
      pod_name = "kong-gateway-0"
    }
  },
  log_request_body = true,
  log_response_body = true,
  max_request_body_size = 524288,  -- 512KB
  max_response_body_size = 1048576,  -- 1MB
  truncate_large_bodies = true,
  batch_max_size = 100,
  flush_timeout = 5,
  retry_count = 3,
  retry_max_attempts = 5,
  retry_base_delay = 500,
  retry_max_delay = 60000
}

-- Configuration for unlimited body logging (use with caution)
config = {
  google_key_file = "/etc/kong/gcp-service-account.json",
  log_id = "kong-api-gateway-full-bodies",
  resource = {
    type = "k8s_container",
    labels = {
      project_id = "my-project",
      cluster_name = "my-cluster",
      namespace_name = "kong",
      pod_name = "kong-gateway-0"
    }
  },
  log_request_body = true,
  log_response_body = true,
  enforce_body_size_limits = false,  -- Disable all body size limits
  batch_max_size = 50,  -- Smaller batch size due to potentially larger payloads
  flush_timeout = 10,   -- Longer flush timeout to accommodate larger processing time
  retry_count = 5       -- More retries for potentially larger payloads
}

-- Configuration with custom HTTP client options
config = {
  google_key_file = "/etc/kong/gcp-service-account.json",
  log_id = "kong-api-gateway-custom-http",
  resource = {
    type = "global",
    labels = {
      project_id = "my-project"
    }
  },
  -- HTTP client customization
  http_timeout = 20000,            -- 20 seconds timeout for slow networks
  http_ssl_verify = false,         -- Disable SSL verification (not recommended for production)
  http_max_body_log_size = 5000,   -- Larger debug logging for troubleshooting
  -- Retry settings for unreliable networks
  retry_max_attempts = 8,
  retry_base_delay = 500,
  retry_max_delay = 60000
}
```

## Performance Considerations

- Enabling body logging will increase memory usage, especially for services with large request/response bodies
- Consider enabling compression on your services to reduce the memory footprint for body logging
- For high-traffic services, you may need to adjust the `batch_max_size` and `flush_timeout` to balance API call frequency with memory usage

## Troubleshooting

Common issues and their solutions:

1. **Authentication Failures**: Ensure your service account has the `logging.write` permission and the key file is readable by Kong
2. **Memory Usage Spikes**: Adjust body size limits or disable body logging for high-throughput services
3. **Log Entries Not Appearing**: Check Kong error logs for batch processing failures and consider increasing retry settings
4. **High API Latency**: Tune batching parameters to reduce the frequency of API calls to Google Cloud

## License

```
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
