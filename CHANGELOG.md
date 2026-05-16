# Changelog

All notable changes to this project will be documented in this file.

## [0.1.3] — 2026-05-17

### Fixed
- Include `lib/tasks/ez_logs_agent.rake` in the published gem. 0.1.2's
  gemspec used `lib/**/*.{rb,tt}` which didn't match `.rake` files; the
  railtie's `rake_tasks do; load 'tasks/...'; end` then raised
  `LoadError` on boot, breaking `assets:precompile` in any host app's
  Docker build. 0.1.2 yanked.

### Note
- 0.1.0, 0.1.1, 0.1.2 are all yanked. Use 0.1.3 or later.

## [0.1.2] — 2026-05-16

### Fixed
- Republish with correct file modes (0644) so the gem loads in
  privilege-dropping containers. 0.1.0 and 0.1.1 were built under a
  tight umask and shipped lib files at 0600, causing `LoadError` in
  any image that drops to a non-root user. Both prior versions yanked.

### Note
- 0.1.1 is yanked. Use 0.1.2 or later.

## [0.1.0] — 2025-12-18

Initial release.

### Added

**Event Capture:**
- HTTP request capture via Rack middleware
- GraphQL metadata enrichment (operation name, operation type)
- Sidekiq job capture via client and server middleware
- ActiveJob capture with Sidekiq adapter detection
- ActiveRecord lifecycle capture (create, update, destroy)

**Correlation:**
- Automatic correlation ID generation for HTTP requests
- Correlation propagation from HTTP to background jobs
- Correlation propagation from job to nested jobs
- Cross-technology correlation (Sidekiq ↔ ActiveJob)

**Transport:**
- Thread-safe in-memory buffer with overflow protection
- HTTP transport with configurable server URL
- Retry logic with exponential backoff
- Background flush scheduler (configurable interval)

**Rails Integration:**
- Zero-config setup via Railtie
- Auto-registration of HTTP middleware
- Auto-registration of Sidekiq middleware
- Auto-installation of ActiveJob hooks
- Auto-installation of database callbacks
- Graceful shutdown with final flush
- Rails generator for initializer (`rails generate ez_logs_agent:install`)

**Configuration:**
- `server_url` — EzLogs Server URL (required)
- `project_token` — Authentication token
- `capture_http` — Enable/disable HTTP capture
- `capture_jobs` — Enable/disable job capture
- `capture_database` — Enable/disable database capture
- `excluded_paths` — Paths to skip in HTTP capture
- `buffer_size` — Maximum events in memory
- `retry_attempts` — Retry count for failed sends
- `send_interval` — Seconds between flushes
- `log_level` — Logging verbosity

### Notes

- Best-effort delivery (events may be lost if server is unreachable)
- Correlation is best-effort (missing correlation IDs are acceptable)
- Not intended as an audit log (use PaperTrail or Audited for compliance)
- Agent never raises exceptions to host application
- Agent never blocks requests or job execution
