# EZLogs Agent

**Drop-in activity logging for Rails applications.**

EZLogs Agent captures what happens in your Rails app — HTTP requests, background jobs, database changes — and sends them to the EZLogs server, where they're transformed into human-readable stories that anyone on your team can understand.

Wire-format identical to the [Next.js sister agent](https://github.com/dezsirazvan/ez_logs/tree/master/ez_logs_agent_nextjs) (`@ezlogs/nextjs`). Same server ingests both. Use Rails on the back end and Next.js on the front end? You see one unified Action timeline.

---

## The Problem

When someone clicks "Reset Password" in your app, a cascade of events unfolds:
- HTTP requests hit your server
- Database records get updated
- Background jobs are queued
- Emails are sent
- Sessions are invalidated

Right now, understanding what actually happened requires:
- Opening multiple tools (application logs, Sidekiq dashboard, database console)
- Piecing together timestamps across different systems
- Reading cryptic stack traces and technical jargon
- Having an engineer translate everything into plain English

**EZLogs solves this.**

Instead of scattered technical logs, you see a complete story:

```
Password Reset — jessica@example.com
2:23 PM, January 15, 2025

  ✓ Reset link created (expires in 1 hour)
  ✓ Email sent to jessica@example.com
  ✓ All active sessions logged out (2 devices)
  ✗ Push notification failed (user has notifications disabled)

Status: Completed successfully
```

Your support team can read that. Your product manager can read that. Your CEO can read that. **No engineer required.**

---

## What EZLogs Is (and Is NOT)

### EZLogs Is:

- **An application-level activity log** — Shows what happened in your system in business terms
- **A bridge between technical systems and business understanding** — Translates technical events into human language
- **Best-effort and non-blocking** — Never impacts your application's performance or reliability
- **Safe to run in production** — Designed to fail gracefully if anything goes wrong

### EZLogs Is NOT:

- **A monitoring tool** — Use Datadog, New Relic, or CloudWatch for performance monitoring
- **A metrics platform** — Use your existing APM for request rates, response times, etc.
- **An audit log** — Use PaperTrail or Audited for compliance and legal requirements
- **A guaranteed delivery system** — Events may be dropped if the server is unreachable (this is intentional)
- **A replacement for debugging tools** — Use Sentry, Bugsnag, or your IDE debugger for code-level debugging

**EZLogs complements your existing tools by focusing on business understanding, not technical signals.**

---

## Installation

### Step 1: Add the Gem

Add to your `Gemfile`:

```ruby
gem 'ez_logs_agent'
```

Then install:

```bash
bundle install
```

### Step 2: Run the Generator

```bash
rails generate ez_logs_agent:install
```

This creates `config/initializers/ez_logs_agent.rb` with all available configuration options and helpful comments.

### Requirements

- **Ruby** >= 3.1.0
- **Rails** (any recent version)
- **Sidekiq** (optional, auto-detected if present)
- **ActiveRecord** (optional, auto-detected if present)

---

## Quick Start

### 1. Get Your API Key

Sign up for EZLogs at [app.ezlogs.io](https://app.ezlogs.io) and create an API key from your dashboard settings.

### 2. Configure the Agent

Edit `config/initializers/ez_logs_agent.rb`:

```ruby
EzLogsAgent.configure do |config|
  # Required: Your EZLogs server URL
  config.server_url = "https://app.ezlogs.io"

  # Required: Your API key from the EZLogs dashboard
  config.project_token = "ezl_your_api_key_here"
end
```

**That's it.** The agent handles everything else automatically:
- No middleware registration needed
- No Sidekiq configuration required
- No ActiveRecord setup necessary

The agent orchestrates itself via a Rails Railtie. When your app boots, event capture begins automatically.

### 3. Verify It's Working

Test your configuration:

```bash
rails ez_logs_agent:test_connection
```

**Successful output:**
```
✅ Configuration is valid
✅ Connection successful (HTTP 200)
✅ Test event sent successfully
✅ All checks passed! EZLogs Agent is configured correctly.
```

If the test fails, you'll see exactly what's wrong and how to fix it.

### 4. Restart Your Application

```bash
# Development
rails server

# Production
# Restart your application using your deployment process
```

Check your Rails logs for the startup message:

```
[EzLogsAgent] Agent initialized successfully
[EzLogsAgent] ✓ HTTP capture enabled
[EzLogsAgent] ✓ Sidekiq capture enabled
[EzLogsAgent] ✓ Database capture enabled
```

### 5. See Your Activity

Visit your EZLogs dashboard and interact with your application. Within seconds, you'll see activity appearing in real-time.

---

## What Gets Captured

EZLogs Agent captures three primary event sources. These are the building blocks that EZLogs Server uses to construct complete activity stories.

### 1. HTTP Requests

Every incoming HTTP request, with intelligent noise filtering:

**What's captured:**
- HTTP method, path, status code, duration
- Controller and action name (for Rails apps)
- GraphQL operation name and type (queries, mutations, subscriptions)
- Request parameters (sanitized automatically)
- Correlation ID (generated automatically)

**Automatic exclusions (no configuration needed):**
- `/rails/active_storage*` — File uploads/downloads
- `/assets*`, `/packs*`, `/vite*` — Static assets (JavaScript, CSS, images)
- `/health*`, `/up`, `/alive`, `/ready`, `/metrics` — Health checks + ops endpoints
- `/favicon.ico`, `/.well-known*`, `/robots.txt`, `/sitemap.xml` — Crawler / browser plumbing
- `/cable*` — ActionCable WebSocket connections
- `/sidekiq`, `/sidekiq/*` — Sidekiq Web UI (auto-polls every few seconds)
- `*/sign_in*`, `*/sign_out*`, `*/login*`, `*/logout*`, `/users/password*`, `/session*` — Auth pages (Devise + common patterns)

**Note on GraphQL:** All GraphQL operations (queries, mutations, subscriptions) are captured. The server classifies queries as "background" significance, allowing users to toggle their visibility in the UI since they're typically read-only operations.

### 2. Background Jobs

Sidekiq and ActiveJob executions:

**What's captured:**
- Job class name, queue name, duration
- Success or failure status with error message (if failed)
- Correlation ID (automatically inherited from the request that enqueued the job)
- Job arguments (sanitized automatically)

**Automatic exclusions (no configuration needed):**
- `SidekiqAlive::Worker` — Sidekiq liveness probe
- `SolidQueue::CleanupJob` — SolidQueue maintenance job
- `SolidQueue::RecurringJob` — SolidQueue scheduler internals

**Supported job systems:**
- Sidekiq (fully supported)
- ActiveJob with any backend (fully supported)

### 3. Database Changes

ActiveRecord create, update, and destroy operations:

**What's captured:**
- Model class name, record ID, operation type (create/update/destroy)
- For creates: initial attribute values
- For updates: one meaningful attribute change (e.g., `status: pending → shipped`)
- For destroys: final attribute values before deletion
- Correlation ID (automatically inherited from the current request or job)

**What's NOT captured:**
- SELECT queries (read operations don't change data)
- Schema migrations (Rails internal operations)
- Bulk operations (e.g., `update_all`, `delete_all`)

**Automatic exclusions (no configuration needed):**
- `sessions` — Session store updates
- `schema_migrations`, `ar_internal_metadata` — Rails schema management
- `active_storage_*` — ActiveStorage internal tables
- `solid_queue_*`, `solid_cache_*`, `solid_cable_*` — Solid* gem internals

---

## How Correlation Works

Events are automatically linked together using a `correlation_id`, allowing EZLogs to reconstruct the complete chain of events triggered by a single user action.

### Automatic Propagation

```
HTTP Request
  └─ generates correlation_id: "req_abc123"
     └─ Database Update (inherits: "req_abc123")
     └─ Background Job #1 (inherits: "req_abc123")
        └─ Database Update (inherits: "req_abc123")
        └─ Background Job #2 (inherits: "req_abc123")
```

**Zero configuration required.** The agent handles correlation propagation automatically through:
- Rack request headers
- Sidekiq job metadata
- Thread-local storage (within a single request)

### Best-Effort Approach

**Important:** Correlation is best-effort, not guaranteed. Some events may have missing correlation IDs in edge cases:
- Jobs triggered by cron or external systems
- Console operations
- Database callbacks outside request/job context

**This is expected and acceptable.** EZLogs will still capture these events—they'll just appear as separate, uncorrelated activities.

**Design principle:** Missing data is acceptable; wrong data is not. The agent never guesses correlation IDs.

---

## Configuration Reference

All options have sensible defaults. **Only `server_url` and `project_token` are required.**

### Minimal Configuration

```ruby
EzLogsAgent.configure do |config|
  config.server_url = "https://app.ezlogs.io"
  config.project_token = "ezl_your_api_key_here"
end
```

### Full Configuration

```ruby
EzLogsAgent.configure do |config|
  # ==========================================
  # Required Settings
  # ==========================================

  # Server URL (where to send events)
  config.server_url = "https://app.ezlogs.io"

  # API Key (get this from your EZLogs dashboard under Settings > API Keys)
  # This is sent as a Bearer token in the Authorization header
  config.project_token = "ezl_your_api_key_here"

  # ==========================================
  # Event Capture Toggles
  # ==========================================

  # Capture HTTP requests (default: true)
  config.capture_http = true

  # Capture background jobs (default: true)
  config.capture_jobs = true

  # Capture database changes (default: true)
  config.capture_database = true

  # ==========================================
  # Exclusion Lists
  # ==========================================

  # Additional HTTP paths to exclude
  # Use * suffix for prefix matching (e.g., "/admin*" matches "/admin/users")
  # These are ADDED to the built-in defaults (health checks, assets, etc.)
  config.excluded_paths = ["/admin*", "/internal*", "/api/internal*"]

  # Additional database tables to exclude
  # These are ADDED to the built-in defaults (sessions, schema_migrations, etc.)
  config.excluded_tables = ["audit_logs", "versions", "paper_trail_versions"]

  # Additional job classes to exclude
  # These are ADDED to the built-in defaults (Sidekiq health checks, etc.)
  config.excluded_job_classes = ["MyApp::HealthCheckJob", "MyApp::MetricsJob"]

  # ==========================================
  # Display Names
  # ==========================================

  # Configure how to display human-readable names for database records
  # This affects how action titles appear (e.g., "User updated 'john@example.com'")
  # See "Display Names" section below for details
  config.display_name_for = {
    "User" => :email,        # Use the email field for User models
    "Product" => :name,      # Use the name field for Product models
    "Order" => :number       # Use the number field for Order models
  }

  # ==========================================
  # Actor Context
  # ==========================================

  # Configure how to extract the "who" (actor) from requests
  # This is opt-in and highly application-specific
  # See "Actor Context" section below for details
  config.actor_from_request = ->(env, controller) {
    return nil unless controller.respond_to?(:current_user)
    user = controller.current_user
    return nil unless user

    {
      id: user.id.to_s,       # Stable identifier
      label: user.email        # Human-readable display (optional)
    }
  }

  # ==========================================
  # Transport Settings
  # ==========================================

  # Maximum events in memory buffer before oldest are dropped
  # Default: 10000 (approximately 1-2MB of memory)
  # Increased for high-volume workloads with many background jobs
  config.buffer_size = 10000

  # Number of retry attempts for failed sends (with exponential backoff)
  # Default: 3 (retries at 1s, 2s, 4s)
  config.retry_attempts = 3

  # Seconds between automatic buffer flushes
  # Default: 3 (events are sent every 3 seconds if buffer has data)
  # More frequent sends improve throughput for high-volume applications
  config.send_interval = 3

  # ==========================================
  # Logging
  # ==========================================

  # Agent log level
  # Options: :debug, :info, :warn, :error
  # Default: :warn (quiet by default; agent only logs warnings + errors)
  # Set to :debug for verbose output during troubleshooting
  config.log_level = :warn
end
```

---

## Display Names — Human-Readable Resource Identifiers

By default, action titles show database record IDs: `"User updated #123"`. With display name resolution, you can show meaningful identifiers instead: `"User updated 'john@example.com'"`.

### Configuration

```ruby
EzLogsAgent.configure do |config|
  config.display_name_for = {
    "User" => :email,      # "User created 'john@example.com'"
    "Product" => :name,    # "Product updated 'Premium Widget'"
    "Order" => :number     # "Order deleted '#ORD-1234'"
  }
end
```

### How It Works

When a database callback fires (create, update, delete), the agent resolves a display name:

1. **If configured:** Use the specified field (e.g., `User → :email`)
2. **Otherwise, try defaults:** `name` → `title` → `number` (in that order)
3. **If nothing found:** Fall back to `#id` (e.g., `#123`)

### Examples

**Before:**
```
User created
Product updated #456
Order deleted #789
```

**After:**
```
User created 'jessica@example.com'
Product updated 'Premium Subscription Plan'
Order deleted '#ORD-2025-0789'
```

### Important Constraints

**Only use direct attributes, not associations.**

```ruby
# ✅ GOOD - Direct attribute
config.display_name_for = { "User" => :email }

# ❌ BAD - Association (triggers database query)
config.display_name_for = { "Order" => :customer_email }
```

**Why?** Associations would trigger additional database queries during event capture, violating the agent's non-blocking guarantee. The display name is resolved using only data already loaded in memory.

---

## Actor Context — Who Triggered This?

EZLogs can track **who** triggered each action. This adds a human face to your activity log.

### Configuration

```ruby
EzLogsAgent.configure do |config|
  config.actor_from_request = ->(env, controller) {
    # Return nil if controller not available or user not authenticated
    return nil unless controller.respond_to?(:current_user)
    user = controller.current_user
    return nil unless user

    # Return actor hash
    {
      id: user.id.to_s,       # Required: stable identifier
      label: user.email        # Optional: human-readable display
    }
  }
end
```

### Hook Parameters

The hook receives two arguments:

- **`env`** (Hash) — Rack environment hash (always present)
- **`controller`** (Object or nil) — Rails controller instance (nil if not available, e.g., for API-only requests)

### Return Value

Return one of:
- **`{ id: String, label: String }`** — For identified actors (label is optional)
- **`nil`** — When actor cannot be determined

### Schema

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | String | Yes | Stable identifier (e.g., user ID, never changes) |
| `label` | String | No | Human-readable display (e.g., email, can change) |

### Design Philosophy

**Actor extraction is opt-in, not automatic.** This prevents:
- Incorrect attribution in impersonation scenarios (admin acting as another user)
- Wrong actors with service accounts or background jobs
- Silent failures with custom authentication systems (Devise, Clearance, Authlogic, custom auth)

When actor is unknown, events are captured with `actor: null`. **Missing data is acceptable; wrong data is not.**

### Examples

**With Devise:**
```ruby
config.actor_from_request = ->(env, controller) {
  return nil unless controller.respond_to?(:current_user)
  user = controller.current_user
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

**With Clearance:**
```ruby
config.actor_from_request = ->(env, controller) {
  return nil unless controller.respond_to?(:current_user)
  user = controller.current_user
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

**With Custom Auth:**
```ruby
config.actor_from_request = ->(env, controller) {
  # Extract from session
  user_id = env["rack.session"]&.dig("user_id")
  return nil unless user_id

  # Lookup user (only if you have fast caching)
  user = User.find_by(id: user_id)
  return nil unless user

  { id: user.id.to_s, label: user.email }
}
```

---

## Safety Guarantees

The agent is designed to be **invisible** to your application. It will never be the reason your app fails.

### Non-Blocking Operation

- **Never raises exceptions** to the host application
- **Never blocks** HTTP requests or background jobs
- **Sends asynchronously** via a background thread
- **Fails gracefully** if the server is unreachable

### Buffer Overflow Protection

- **Drops oldest events** when buffer is full (controlled by `buffer_size`)
- **Never crashes** from memory pressure
- **Logs warnings** when buffer approaches capacity

### Network Failure Handling

- **Retries with exponential backoff** (controlled by `retry_attempts`)
- **Gives up gracefully** after max retries
- **Your application continues normally** if EZLogs Server is down

### Graceful Shutdown

- **Flushes remaining events** when Rails shuts down
- **Waits briefly** for final send (non-blocking)
- **Never prevents** application shutdown

**Design principle:** Your application's reliability is more important than capturing every event. EZLogs is best-effort, not guaranteed delivery.

---

## Testing Your Configuration

After installation, verify everything is working:

```bash
rails ez_logs_agent:test_connection
```

### What This Command Does

1. ✅ Validates your configuration (required fields, valid URLs, etc.)
2. ✅ Tests connectivity to the EZLogs server
3. ✅ Sends a test event
4. ✅ Confirms the server accepted it (HTTP 200 response)

### Successful Output

```
[EzLogsAgent] Testing connection to https://app.ezlogs.io...
✅ Configuration is valid
✅ Connection successful (HTTP 200)
✅ Test event sent successfully
✅ All checks passed! EZLogs Agent is configured correctly.

Next steps:
  1. Restart your Rails application
  2. Visit your EZLogs dashboard
  3. Interact with your application to generate events
```

### Failed Output

If the test fails, you'll see exactly what's wrong:

```
[EzLogsAgent] Testing connection to https://app.ezlogs.io...
❌ Connection failed (HTTP 401 Unauthorized)

Possible causes:
  - Invalid API key (project_token)
  - API key has been revoked
  - Check your project_token in config/initializers/ez_logs_agent.rb

Please fix the error and run this command again.
```

---

## Troubleshooting

### Quick Diagnosis

**Start here.** This command catches 90% of configuration issues immediately:

```bash
rails ez_logs_agent:test_connection
```

---

### No Events Showing Up

**Symptoms:** Your EZLogs dashboard is empty after restarting your application.

**Debug steps:**

1. **Run the connection test:**
   ```bash
   rails ez_logs_agent:test_connection
   ```

2. **Check Rails logs** for agent messages:
   ```
   [EzLogsAgent] Agent initialized successfully
   [EzLogsAgent] ✓ HTTP capture enabled
   [EzLogsAgent] Sending batch of 3 events...
   [EzLogsAgent] Batch sent successfully (HTTP 200)
   ```

3. **Enable debug logging** in `config/initializers/ez_logs_agent.rb`:
   ```ruby
   config.log_level = :debug
   ```
   Then restart Rails and check logs for detailed capture information.

4. **Verify network connectivity:**
   ```bash
   curl -I https://app.ezlogs.io
   ```

5. **Check firewall rules:** Ensure your application can reach the EZLogs server on port 443 (HTTPS).

---

### Configuration Validation Errors at Boot

**Symptoms:** Rails starts but shows warnings from EZLogs Agent.

**Example output:**
```
[Railtie] Configuration validation failed:
  - server_url is required. Set it in config/initializers/ez_logs_agent.rb
[Railtie] Agent initialization skipped. Please fix configuration errors.
```

**Solution:** Fix the errors listed in the warning message and restart Rails.

Common validation errors:
- `server_url is required` → Set `config.server_url`
- `project_token is not set` → Set `config.project_token`
- `server_url must start with http:// or https://` → Fix URL format

---

### Authentication Errors (HTTP 401)

**Symptoms:** Connection test or agent logs show `HTTP 401 Unauthorized`.

**Debug steps:**

1. **Verify your API key:**
   - Log into your EZLogs dashboard
   - Go to Settings > API Keys
   - Copy the active API key
   - Paste it into `config.project_token` (include the `ezl_` prefix)

2. **Check for extra characters:**
   ```ruby
   # ❌ BAD - Extra quotes or spaces
   config.project_token = " ezl_abc123 "

   # ✅ GOOD
   config.project_token = "ezl_abc123"
   ```

3. **Ensure the API key is active:**
   - Check the EZLogs dashboard to confirm the key hasn't been revoked
   - If revoked, create a new key and update your configuration

---

### Sidekiq Jobs Not Captured

**Symptoms:** HTTP requests appear in EZLogs but background jobs don't.

**Debug steps:**

1. **Verify Sidekiq is running:**
   ```bash
   # Should show running Sidekiq processes
   ps aux | grep sidekiq
   ```

2. **Check agent configuration:**
   ```ruby
   # Ensure jobs capture is enabled (this is the default)
   config.capture_jobs = true
   ```

3. **Look for Sidekiq registration in logs:**
   ```
   [Railtie] Sidekiq server middleware registered
   ```
   **Note:** This message only appears in Sidekiq worker processes, not web processes.

4. **Verify job classes aren't excluded:**
   Check `config.excluded_job_classes` to ensure your jobs aren't being filtered out.

5. **Run a test job:**
   ```ruby
   # In Rails console
   class TestJob < ApplicationJob
     def perform
       Rails.logger.info "Test job executed"
     end
   end

   TestJob.perform_later
   ```
   Check your EZLogs dashboard for the job execution.

---

### Database Events Missing

**Symptoms:** HTTP requests and jobs appear, but database changes don't.

**Debug steps:**

1. **Verify ActiveRecord is present:**
   ```bash
   # In Rails console
   defined?(ActiveRecord)  # Should return "constant"
   ```

2. **Check agent configuration:**
   ```ruby
   # Ensure database capture is enabled (this is the default)
   config.capture_database = true
   ```

3. **Look for database capture registration in logs:**
   ```
   [Railtie] Database capture installed
   ```

4. **Verify models aren't excluded:**
   Check `config.excluded_tables` to ensure your tables aren't being filtered out.

5. **Remember: Only create/update/destroy are captured:**
   - ✅ `User.create(...)` — Captured
   - ✅ `user.update(...)` — Captured
   - ✅ `user.destroy` — Captured
   - ❌ `User.find(...)` — NOT captured (read-only)
   - ❌ `User.update_all(...)` — NOT captured (bulk operation)

---

### Events Appearing Late

**Symptoms:** Events show up in your dashboard with a delay.

**This is normal.** Events are sent in batches every 3 seconds by default.

**To reduce latency further** (at the cost of more network requests):
```ruby
# Send events every 1-2 seconds instead of 3
config.send_interval = 1
```

**Note:** Even with `send_interval = 2`, there's still processing time on the server. Real-time is not guaranteed.

---

### Correlation IDs Missing

**Symptoms:** Events appear as separate activities instead of being grouped together.

**This is expected in some scenarios:**
- Jobs triggered by cron or external systems
- Console operations (`rails console`)
- Database callbacks outside request/job context
- Cross-process job chains (e.g., Job A in Process 1 enqueues Job B in Process 2)

**This is normal and acceptable.** Correlation is best-effort, not guaranteed.

**If correlation is missing when it should be present:**
1. Enable debug logging: `config.log_level = :debug`
2. Look for correlation_id in logs: `[EzLogsAgent] Captured HTTP event with correlation_id: req_abc123`
3. Check that jobs are enqueued within the same request context

---

### Performance Impact

**Symptoms:** Concerned about memory usage or application performance.

**The agent is designed to be lightweight:**
- **Memory:** ~1-2MB for default buffer (10,000 events)
- **CPU:** Negligible (background thread does all work)
- **Latency:** Zero added to requests (capture is asynchronous)

**If you experience issues:**

1. **Reduce buffer size** (for low-volume apps):
   ```ruby
   # Reduce from 10000 to 5000 events
   config.buffer_size = 5000
   ```

2. **Increase send interval** (events sent less frequently):
   ```ruby
   # Send every 5-10 seconds instead of 3
   config.send_interval = 5
   ```

3. **Disable specific capture types:**
   ```ruby
   # Database changes can be noisy in write-heavy apps
   config.capture_database = false
   ```

---

### Understanding Agent Log Messages

**Normal operation:**
```
[EzLogsAgent] Agent initialized successfully
[EzLogsAgent] Sending batch of 12 events...
[EzLogsAgent] Batch sent successfully (HTTP 200)
```

**Warnings (usually safe to ignore):**
```
[EzLogsAgent] Buffer full, dropping oldest events
→ Your app is generating more events than can be sent
→ Increase buffer_size or send_interval
```

**Errors (need attention):**
```
[EzLogsAgent] Failed to send events (HTTP 401)
→ Invalid API key, check config.project_token

[EzLogsAgent] Failed to send events (timeout)
→ Network connectivity issue or server is down
→ Events will be retried automatically

[EzLogsAgent] Configuration validation failed
→ Fix configuration errors and restart Rails
```

---

### Getting Help

If you're still stuck after trying the above:

1. **Check GitHub Issues:** [github.com/dezsirazvan/ez_logs](https://github.com/dezsirazvan/ez_logs)
2. **Open a new issue** with:
   - Rails version and Ruby version
   - Relevant logs (set `config.log_level = :debug`)
   - Output of `rails ez_logs_agent:test_connection`
   - Steps to reproduce the problem

---

## How It Works

A visual overview of the agent's architecture:

```
Your Rails Application
       │
       ├─ HTTP Request arrives
       │     └─ Rack middleware captures event
       │             └─ Adds to Buffer
       │
       ├─ Background Job runs
       │     └─ Sidekiq middleware captures event
       │             └─ Adds to Buffer
       │
       └─ Database record changes
             └─ ActiveRecord callback captures event
                     └─ Adds to Buffer

                            │
                            ▼
                    ┌───────────────┐
                    │    Buffer     │  (thread-safe, in-memory, circular)
                    │ 10,000 events │
                    └───────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │FlushScheduler │  (background thread, every 3s)
                    └───────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │   Transport   │  (HTTP POST with retry logic)
                    │               │  (Authorization: Bearer token)
                    └───────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │ EZLogs Server │  (groups events into stories)
                    └───────────────┘
```

**Key points:**
- Capture happens **synchronously** (microseconds, no blocking)
- Sending happens **asynchronously** (background thread)
- Buffer is **circular** (oldest events dropped when full)
- Transport uses **exponential backoff** (1s, 2s, 4s retries)

---

## Development

### Running Tests

```bash
cd ez_logs_agent
bundle install
bundle exec rspec
```

### Test Coverage

786+ tests covering:
- HTTP request capture
- GraphQL support
- Background job capture (Sidekiq + ActiveJob)
- Database callbacks (create, update, destroy)
- Correlation propagation
- Actor context extraction
- Display name resolution
- Buffer overflow handling
- Transport retry logic
- Configuration validation

---

## License

MIT License. See [LICENSE.txt](LICENSE.txt) for details.

---

## Contributing

We welcome bug reports and pull requests!

**To report a bug:**
1. Check existing [GitHub Issues](https://github.com)
2. Open a new issue with reproduction steps

**To contribute code:**
1. Fork the repository
2. Create a feature branch
3. Write tests for your changes
4. Ensure all tests pass: `bundle exec rspec`
5. Submit a pull request with a clear description

**Code style:**
- Follow the existing Ruby style
- Write descriptive commit messages
- Update documentation for user-facing changes

---

## Status

- **786 tests**, all green
- **Wire-format parity-tested** against the Next.js agent's fixtures (every event shape byte-for-byte identical)
- **Production-shipping** in multiple Rails apps including the [Bookhouse demo](https://github.com/dezsirazvan/ez_logs/tree/master/demo_apps/bookhouse) — Rails 8 + Sidekiq + Devise, exercises every capture path

---

## Support

- **GitHub Issues:** [Report a bug](https://github.com/dezsirazvan/ez_logs/issues)
- **Email:** support@ezlogs.io

---

**Made with clarity in mind. Built for everyone on your team, not just engineers.**
