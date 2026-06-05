# Changelog

All notable changes to this project will be documented in this file.

## [0.1.10] — 2026-06-05

### Fixed
- `Sanitizer` no longer collapses ActiveJob keyword-argument hashes
  (those tagged with `_aj_ruby2_keywords`) to `"[Object]"` at the
  depth-3 cap. ActionMailer puts kwargs at two wrapper layers — an
  outer `{"args" => [kwargs_hash], "_aj_ruby2_keywords" => ["args"]}`
  payload and the kwargs hash itself, also marked. Each layer is
  framework noise; the depth budget now skips them so real kwargs
  survive the wire (e.g. `CompanyMailer.deleted(admin_email:, ...)`
  now ships `admin_email`/`company_name`/`deleted_at` instead of a
  single `"[Object]"`).

The carve-out is narrow: only hashes that actually carry the
`_aj_ruby2_keywords` marker are exempt. Customer-data hashes
without the marker still hit the depth cap unchanged, and
sensitive-key filtering (passwords, tokens, …) still runs on the
real kwargs entries — the wrapper is free to descend into, but
nothing inside it is exempt from masking. No wire-format change.

## [0.1.9] — 2026-06-05

### Fixed
- `Sanitizer` no longer collapses ActiveJob record references
  (`{"_aj_globalid" => "gid://app/Model/id"}`) to `"[Object]"` at the
  depth-3 cap. These one-key wrapper hashes pass through verbatim so
  the server can display *which* record a job ran on
  (e.g. ActionMailer's `Record 1` field now reads `User #42` instead
  of `[Object]`).

The carve-out is narrow: only the exact `{"_aj_globalid" => "gid://..."}`
shape is exempt. Multi-key hashes, non-GID values, and any other
nested structure still hit the existing graph-protection rules
(depth cap, array truncation, non-primitive collapse) unchanged. No
wire-format change.

## [0.1.8] — 2026-05-29

### Changed
- Install template (`rails generate ez_logs_agent:install`) now
  pre-fills `config.server_url` with the real SaaS endpoint
  (`https://app.ezlogs.io`) and `config.project_token` with
  `ENV["EZLOGS_API_KEY"]`, uncommented. Self-hosters override via
  `ENV["EZLOGS_SERVER_URL"]`. New customers only need to set one
  env var (the API key); they no longer have to know to uncomment
  the URL line or guess the right value.
- Documentation (`QUICKSTART.md`, `CONFIGURATION.md`, `FAQ.md`) uses
  the real product URLs (`app.ezlogs.io`, `ezlogs.io/pricing`)
  instead of `your-ezlogs-server.com` placeholders.

No wire-format or runtime-behavior changes. Existing customers'
already-generated initializer files are untouched — the generator
doesn't rewrite them. Only fresh installs see the new defaults.

## [0.1.7] — 2026-05-28

### Changed
- Gem `homepage` now points at the product site (`https://ezlogs.io/`)
  instead of the GitHub mirror, so the RubyGems "Homepage" link sends
  installers to the product. `source_code_uri` still points at the
  mirror. Metadata-only release; no code or wire change.

## [0.1.6] — 2026-05-24

### Added
- Optional `actor.principal` sub-field (`{ id:, label? }`) on the wire,
  carrying the human a `kind: "agent"` or `kind: "hybrid"` actor is
  acting on behalf of. Drops silently if malformed; existing callers
  unaffected. Lets the server narrate agent actions as
  "Claude updated employee, on behalf of Razvan" instead of
  attributing the change to either party alone.

### Internal
- Dropped a stray gemspec bump to `sidekiq ~> 8.1` that landed via an
  auto-merged dependabot PR without re-resolving `Gemfile.lock`. Dev
  deps are back in sync with the lockfile (`rails ~> 7.0`,
  `sqlite3 ~> 1.6`, `sidekiq ~> 7.0`); no runtime change for customers.

## [0.1.5] — 2026-05-17 — security release

### Security
- `DatabaseCapturer` no longer captures columns the host app declared
  `encrypts :foo` on. Rails 7+ decrypts attributes in memory before
  `saved_changes` fires, so without this guard the plaintext of every
  encrypted column was landing on the wire and in the EZLogs UI on
  every create / update. The new policy is declarative: at capture
  time we read `record.class.encrypted_attributes` (Rails 7+) and drop
  every name in that set, regardless of column name. If the host app
  encrypted it, we never capture it. Upgrade is strongly recommended
  for any deployment whose models use `encrypts`. Customers running
  0.1.4 or earlier should also scrub historical events for the
  affected column names — the data leaked in the past will stay in
  the event store until masked.
- `SENSITIVE_PATTERNS` (the secondary name-based denylist) now also
  matches `private_key`, `public_key`, `signing_key`, `pem`, `cipher`,
  `nonce`, `salt`, `digest`, `signature`, `hmac`. Belt-and-suspenders
  for columns that carry sensitive material but weren't declared
  `encrypts` (legacy code, manual hashing, externally-generated
  material).

## [0.1.4] — 2026-05-17

### Fixed
- `ActiveJobCapturer#sidekiq_adapter?` no longer triggers Rails to
  autoload `ActiveJob::QueueAdapters::SidekiqAdapter`. Rails registers
  that constant for lazy autoload even when sidekiq isn't in the host's
  bundle; the old `is_a?` check forced the adapter file to load, which
  `require`s sidekiq and raised `Gem::LoadError: sidekiq is not part of
  the bundle` on every job run for hosts using SolidQueue, GoodJob, or
  any other non-Sidekiq adapter. The check now compares the adapter
  class name string and never references the constant.

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
