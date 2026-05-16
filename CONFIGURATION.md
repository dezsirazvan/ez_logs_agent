# EZLogs Agent — Configuration Reference

Complete reference for all configuration options.

---

## Table of Contents

- [Required Settings](#required-settings)
- [Event Capture Toggles](#event-capture-toggles)
- [Exclusion Lists](#exclusion-lists)
- [Display Names](#display-names)
- [Actor Context](#actor-context)
- [Transport Settings](#transport-settings)
- [Logging](#logging)
- [Environment Variables](#environment-variables)
- [Validation](#validation)

---

## Required Settings

### `server_url`

**Type:** String
**Required:** Yes
**Default:** None

The URL of your EZLogs server where events will be sent.

**Example:**
```ruby
config.server_url = "https://your-ezlogs-server.com"
```

**Validation:**
- Must be present
- Must start with `http://` or `https://`
- Must be a valid URL format

**Common values:**
- Production: `https://your-ezlogs-server.com`
- Staging: `https://staging.your-ezlogs-server.com`
- Development: `http://localhost:3000`

---

### `project_token`

**Type:** String
**Required:** Yes (for authentication)
**Default:** None

Your API key from the EZLogs dashboard. This is sent as a Bearer token in the `Authorization` header.

**Example:**
```ruby
config.project_token = "ezl_abc123xyz..."
```

**Best practice:** Use environment variables

```ruby
config.project_token = ENV['EZLOGS_API_KEY']
```

**Validation:**
- Should be present (warning if missing)
- Never logged or exposed in error messages
- Sent over HTTPS only

**Where to get it:**
1. Log into your EZLogs dashboard
2. Go to Settings → API Keys
3. Create a new key or copy an existing one
4. Keys start with `ezl_` prefix

---

## Event Capture Toggles

### `capture_http`

**Type:** Boolean
**Required:** No
**Default:** `true`

Enable or disable HTTP request capture.

**Example:**
```ruby
config.capture_http = true
```

**When enabled, captures:**
- HTTP method, path, status code, duration
- Controller and action name (Rails apps)
- GraphQL operation name and type (queries, mutations, subscriptions)
- Request correlation ID

**When to disable:**
- API-only apps where HTTP requests aren't meaningful
- Reducing noise in write-heavy applications

---

### `capture_jobs`

**Type:** Boolean
**Required:** No
**Default:** `true`

Enable or disable background job capture.

**Example:**
```ruby
config.capture_jobs = true
```

**When enabled, captures:**
- Sidekiq job executions
- ActiveJob executions (any backend)
- Job class, queue, duration
- Success/failure status with error messages

**When to disable:**
- Apps without background jobs
- Reducing noise from high-frequency jobs

---

### `capture_database`

**Type:** Boolean
**Required:** No
**Default:** `true`

Enable or disable database change capture.

**Example:**
```ruby
config.capture_database = true
```

**When enabled, captures:**
- ActiveRecord create, update, destroy operations
- Model class, record ID, operation type
- For updates: meaningful attribute changes

**When to disable:**
- Write-heavy applications with excessive database activity
- Apps where database changes aren't meaningful to business logic

---

## Exclusion Lists

All exclusion lists are **additive** — they add to built-in defaults, not replace them.

### `excluded_paths`

**Type:** Array of Strings
**Required:** No
**Default:** `[]` (uses built-in defaults only)

Additional HTTP paths to exclude from capture.

**Example:**
```ruby
config.excluded_paths = ["/admin*", "/internal*", "/api/internal*"]
```

**Pattern matching:**
- Use `*` suffix for prefix matching
- `/admin*` matches `/admin`, `/admin/users`, `/admin/anything`
- Exact matches without `*` are supported but rarely needed

**Built-in exclusions (automatically excluded):**
- `/rails/active_storage*` — File uploads/downloads
- `/assets*`, `/packs*`, `/vite*` — Static assets
- `/health*`, `/up` — Health check endpoints
- `/favicon.ico` — Browser requests

**Common additions:**
- `/admin*` — Admin panel requests
- `/internal*` — Internal API endpoints
- `/debug*` — Debugging tools

---

### `excluded_tables`

**Type:** Array of Strings
**Required:** No
**Default:** `[]` (uses built-in defaults only)

Additional database tables to exclude from capture.

**Example:**
```ruby
config.excluded_tables = ["audit_logs", "versions", "paper_trail_versions"]
```

**Table names:**
- Use exact table name (lowercase, plural)
- No prefix matching — must match exactly

**Built-in exclusions (automatically excluded):**
- `sessions` — Session store updates
- `schema_migrations`, `ar_internal_metadata` — Rails internals
- `active_storage_*` — ActiveStorage tables
- `solid_queue_*`, `solid_cache_*`, `solid_cable_*` — Solid* gem internals

**Common additions:**
- `audit_logs`, `versions`, `paper_trail_versions` — Audit trail gems
- `delayed_jobs` — Delayed::Job queue table
- `que_jobs` — Que job queue table
- Internal tables specific to your app

---

### `excluded_job_classes`

**Type:** Array of Strings
**Required:** No
**Default:** `[]` (uses built-in defaults only)

Additional job classes to exclude from capture.

**Example:**
```ruby
config.excluded_job_classes = [
  "MyApp::HealthCheckJob",
  "MyApp::MetricsJob",
  "MyApp::HeartbeatJob"
]
```

**Class names:**
- Use full class name including module namespaces
- `"MyApp::SomeJob"` not `"SomeJob"`

**Built-in exclusions (automatically excluded):**
- `SidekiqAlive::Worker` — Sidekiq health check
- `SolidQueue::CleanupJob` — SolidQueue maintenance
- `SolidQueue::RecurringJob` — SolidQueue scheduler

**Common additions:**
- Health check jobs
- Metrics collection jobs
- Heartbeat/ping jobs
- Internal maintenance jobs

---

## Display Names

### `display_name_for`

**Type:** Hash (String → Symbol)
**Required:** No
**Default:** `{}` (uses fallback strategy for all models)

Configure how to display human-readable names for database records.

**Example:**
```ruby
config.display_name_for = {
  "User" => :email,
  "Product" => :name,
  "Order" => :number,
  "Company" => :name
}
```

**Key:** Model class name (String)
**Value:** Attribute name (Symbol)

### How It Works

When a database callback fires, the agent resolves a display name:

1. **If configured** for the model → use that attribute
2. **Otherwise, try defaults** → `name`, `title`, `number` (in that order)
3. **If nothing found** → fall back to `#id`

### Examples

**Before configuration:**
```
User created #123
Product updated #456
Order deleted #789
```

**After configuration:**
```
User created 'jessica@example.com'
Product updated 'Premium Widget'
Order deleted '#ORD-2025-0789'
```

### Important Constraints

**✅ Use direct attributes only:**
```ruby
# GOOD
config.display_name_for = { "User" => :email }
```

**❌ Never use associations:**
```ruby
# BAD - Triggers database query
config.display_name_for = { "Order" => :customer_email }
```

**Why?** Associations trigger additional database queries, violating the agent's non-blocking guarantee.

**Performance:** Display names are resolved at capture time using only data already loaded in memory.

---

## Actor Context

### `actor_from_request`

**Type:** Lambda/Proc
**Required:** No
**Default:** `nil` (actor tracking disabled)

Configure how to extract the "who" (actor) from HTTP requests.

**Example:**
```ruby
config.actor_from_request = ->(env, controller) {
  return nil unless controller.respond_to?(:current_user)
  user = controller.current_user
  return nil unless user

  {
    id: user.id.to_s,
    label: user.email
  }
}
```

### Parameters

**`env`** (Hash)
- Rack environment hash
- Always present
- Contains request headers, session, etc.

**`controller`** (Object or nil)
- Rails controller instance
- `nil` if controller not available (e.g., Rack apps, API-only mode)

### Return Value

Return one of:

**Actor hash:**
```ruby
{
  id: "123",              # Required: stable identifier
  label: "user@email.com" # Optional: human-readable display
}
```

**Nil (actor unknown):**
```ruby
nil
```

### Schema

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | String | Yes | Stable identifier (e.g., user ID). Never changes. |
| `label` | String | No | Human-readable display (e.g., email). Can change. |

### Examples

**Devise:**
```ruby
config.actor_from_request = ->(env, controller) {
  return nil unless controller.respond_to?(:current_user)
  user = controller.current_user
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

**Clearance:**
```ruby
config.actor_from_request = ->(env, controller) {
  return nil unless controller.respond_to?(:current_user)
  user = controller.current_user
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

**Custom session-based auth:**
```ruby
config.actor_from_request = ->(env, controller) {
  user_id = env["rack.session"]&.dig("user_id")
  return nil unless user_id

  # Only if you have fast caching
  user = User.find_by(id: user_id)
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

**API token auth:**
```ruby
config.actor_from_request = ->(env, controller) {
  token = env["HTTP_AUTHORIZATION"]&.split(" ")&.last
  return nil unless token

  # Lookup user by API token
  user = User.find_by(api_token: token)
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

### Design Philosophy

**Actor extraction is opt-in, not automatic.**

This prevents:
- Incorrect attribution (admin impersonating another user)
- Wrong actors (service accounts, background jobs)
- Silent failures (custom auth systems)

**When actor is unknown, events are captured with `actor: null`.**

**Design principle:** Missing data is acceptable; wrong data is not.

---

## Transport Settings

### `buffer_size`

**Type:** Integer
**Required:** No
**Default:** `10000`

Maximum number of events to buffer in memory before oldest events are dropped.

**Example:**
```ruby
config.buffer_size = 10000
```

**Memory usage:**
- Default (10000 events) ≈ 1MB - 2MB
- 5000 events ≈ 500KB - 1MB
- 20000 events ≈ 2MB - 4MB

**When to adjust:**
- **Increase to 20000** if you see "Buffer full, dropping events" warnings
- **Decrease to 5000** if memory usage is a concern (low-volume apps)
- **Default (10000) is optimized** for high-volume applications with many background jobs

**Buffer behavior:**
- Circular buffer (oldest events dropped when full)
- Thread-safe
- Non-blocking

---

### `send_interval`

**Type:** Integer (seconds)
**Required:** No
**Default:** `3`

How often (in seconds) to flush the buffer and send events to the server.

**Example:**
```ruby
config.send_interval = 3
```

**Trade-offs:**

| Value | Latency | Network Usage |
|-------|---------|---------------|
| 1s | Lower (more real-time) | Higher (more requests) |
| 3s | Balanced (default) | Balanced |
| 5s | Slightly higher latency | Lower requests |
| 10s | Higher (more delay) | Lower (fewer requests) |

**When to adjust:**
- **Decrease to 1-2s** for more real-time updates
- **Increase to 5-10s** to reduce network traffic for low-volume apps
- **Default (3s) is optimized** for high-volume applications with good throughput

**Note:** Events are also sent when buffer is full, regardless of interval.

---

### `retry_attempts`

**Type:** Integer
**Required:** No
**Default:** `3`

Number of retry attempts for failed sends (with exponential backoff).

**Example:**
```ruby
config.retry_attempts = 3
```

**Retry schedule (default):**
1. First attempt: immediate
2. Retry 1: after 1 second
3. Retry 2: after 2 seconds
4. Retry 3: after 4 seconds
5. Give up

**When to adjust:**
- **Increase (4-5)** if network is unreliable
- **Decrease (1-2)** if you prefer to drop events quickly
- **Set to 0** to disable retries (not recommended)

**After max retries:**
- Events are dropped
- Warning is logged
- Application continues normally

---

## Logging

### `log_level`

**Type:** Symbol
**Required:** No
**Default:** `:info`

Agent log verbosity level.

**Example:**
```ruby
config.log_level = :info
```

**Options:**

| Level | What's Logged |
|-------|---------------|
| `:debug` | Everything (capture events, buffer state, send attempts) |
| `:info` | Initialization, sends, warnings (default) |
| `:warn` | Warnings and errors only |
| `:error` | Errors only |

**Debug output example:**
```
[EzLogsAgent] Captured HTTP event: GET /users (200, 45ms)
[EzLogsAgent] Captured Database event: User#create (id: 123)
[EzLogsAgent] Buffer: 12 events
[EzLogsAgent] Sending batch of 12 events...
[EzLogsAgent] Batch sent successfully (HTTP 200, 120ms)
```

**Info output example (default):**
```
[EzLogsAgent] Agent initialized successfully
[EzLogsAgent] Sending batch of 12 events...
[EzLogsAgent] Batch sent successfully (HTTP 200)
```

**When to use debug:**
- Troubleshooting missing events
- Verifying capture is working
- Debugging correlation issues

**Note:** Debug level can be verbose in high-traffic applications.

---

## Environment Variables

While not directly supported as a configuration option, you can use environment variables for any setting:

### Recommended Pattern

```ruby
EzLogsAgent.configure do |config|
  config.server_url = ENV.fetch('EZLOGS_SERVER_URL')
  config.project_token = ENV.fetch('EZLOGS_API_KEY')

  config.capture_http = ENV.fetch('EZLOGS_CAPTURE_HTTP', 'true') == 'true'
  config.capture_jobs = ENV.fetch('EZLOGS_CAPTURE_JOBS', 'true') == 'true'
  config.capture_database = ENV.fetch('EZLOGS_CAPTURE_DATABASE', 'true') == 'true'

  config.buffer_size = ENV.fetch('EZLOGS_BUFFER_SIZE', '10000').to_i
  config.send_interval = ENV.fetch('EZLOGS_SEND_INTERVAL', '3').to_i
  config.retry_attempts = ENV.fetch('EZLOGS_RETRY_ATTEMPTS', '3').to_i

  config.log_level = ENV.fetch('EZLOGS_LOG_LEVEL', 'info').to_sym
end
```

### Example `.env` File

```bash
EZLOGS_SERVER_URL=https://your-ezlogs-server.com
EZLOGS_API_KEY=ezl_your_api_key_here

# Optional
EZLOGS_CAPTURE_HTTP=true
EZLOGS_CAPTURE_JOBS=true
EZLOGS_CAPTURE_DATABASE=true
EZLOGS_BUFFER_SIZE=10000
EZLOGS_SEND_INTERVAL=3
EZLOGS_RETRY_ATTEMPTS=3
EZLOGS_LOG_LEVEL=info
```

---

## Validation

Configuration is validated when Rails boots. Errors and warnings are logged.

### Error Messages

**Missing server_url:**
```
[Railtie] Configuration validation failed:
  - server_url is required. Set it in config/initializers/ez_logs_agent.rb
[Railtie] Agent initialization skipped. Please fix configuration errors.
```

**Invalid server_url:**
```
[Railtie] Configuration validation failed:
  - server_url must start with http:// or https://
[Railtie] Agent initialization skipped. Please fix configuration errors.
```

### Warning Messages

**Missing project_token:**
```
[Railtie] Configuration warnings:
  - project_token is not set. Authentication may fail if the server requires it.
[Railtie] Agent will attempt to initialize without authentication.
```

### Validation Rules

| Setting | Validation |
|---------|-----------|
| `server_url` | Must be present, must start with `http://` or `https://` |
| `project_token` | Warning if missing (not required but recommended) |
| `buffer_size` | Must be positive integer |
| `send_interval` | Must be positive integer |
| `retry_attempts` | Must be non-negative integer |
| `log_level` | Must be one of: `:debug`, `:info`, `:warn`, `:error` |

**If validation fails:**
- Agent initialization is skipped
- Application starts normally (non-blocking)
- Fix errors and restart Rails

---

## Complete Example

Here's a fully configured example with all options:

```ruby
EzLogsAgent.configure do |config|
  # ==========================================
  # Required
  # ==========================================
  config.server_url = ENV.fetch('EZLOGS_SERVER_URL')
  config.project_token = ENV.fetch('EZLOGS_API_KEY')

  # ==========================================
  # Event Capture
  # ==========================================
  config.capture_http = true
  config.capture_jobs = true
  config.capture_database = true

  # ==========================================
  # Exclusions
  # ==========================================
  config.excluded_paths = ["/admin*", "/internal*"]
  config.excluded_tables = ["audit_logs", "versions"]
  config.excluded_job_classes = ["MyApp::HealthCheckJob"]

  # ==========================================
  # Display Names
  # ==========================================
  config.display_name_for = {
    "User" => :email,
    "Product" => :name,
    "Order" => :number
  }

  # ==========================================
  # Actor Context
  # ==========================================
  config.actor_from_request = ->(env, controller) {
    return nil unless controller.respond_to?(:current_user)
    user = controller.current_user
    return nil unless user

    { id: user.id.to_s, label: user.email }
  }

  # ==========================================
  # Transport
  # ==========================================
  config.buffer_size = 10000
  config.send_interval = 3
  config.retry_attempts = 3

  # ==========================================
  # Logging
  # ==========================================
  config.log_level = :info
end
```

---

## See Also

- [QUICKSTART.md](QUICKSTART.md) — Getting started guide
- [README.md](README.md) — Full documentation
- [FAQ.md](FAQ.md) — Frequently asked questions
- [Troubleshooting](README.md#troubleshooting) — Common issues and solutions

---

**Questions?** [Open an issue](https://github.com/your-org/ez_logs/issues) or email support@ezlogs.com
