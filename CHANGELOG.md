# Changelog

All notable changes to this project will be documented in this file.

## [0.2.15] — 2026-11-22

### Fixed
- **A Sidekiq job's retries stay one action, for real.** 0.2.14 kept the id in the running job's hash, but Sidekiq retries the job from its original JSON, so the id was lost. A job enqueued outside any action (a console, a task, a scheduler) now gets its own correlation id when it is enqueued, in its payload, which every retry carries. A job enqueued in a request still joins that request's action; a console line's or task's own id is still never carried.

## [0.2.14] — 2026-11-22

### Fixed
- **A Sidekiq job's retries stay one action.** A job enqueued outside a request (a console, a task, another job) got a new correlation id on every run, so one failing job read as one failed action per attempt. The id made on its first run is now kept in the job's payload, which Sidekiq pushes again for a retry; EZLogs reads "tried to charge card 3 times but it failed". A retry more than an hour later is its own action, as before.

## [0.2.13] — 2026-11-22

### Fixed
- **A sign-out names the person who signed out (Devise / Warden).** The actor is read at the end of a request, when a sign-out has already cleared it. The agent now remembers the user Warden passes to `before_logout` (no fetch, no app code run at that moment) and, only when the end-of-request read finds no one, asks your `actor_from_request` hook once more with `current_user` answering that user. Only for a sign-out the person asked for (a sessions controller's destroy, a sign-out / log-out route; a logout Warden forces in another request names no one), and `current_user` answers only for the default scope. The sign-out itself is unchanged and nothing is added to its time.

## [0.2.12] — 2026-11-22

### Fixed
- **A write the app refused with an alert reads as refused, not done.** A POST, PUT, PATCH or DELETE that redirects, wrote no row and leaves `flash[:alert]` or `flash[:error]` for the next page (the Rails and Devise convention for "that didn't work": a refund not issued, a review rejected) is now a failure, with the alert's text (up to 200 characters) as its reason. Only an alert set by that request counts, never one carried over from the page before; a notice, a write that saved rows, a GET or a non-redirect stay successes. The flash is only read, never changed. A write made only through raw SQL (`connection.execute`) or in another thread isn't seen as a write, so such a request with an alert reads as refused.

## [0.2.11] — 2026-11-21

### Fixed
- **A value written into a bulk write's SQL is never sent:** `Review.where("body LIKE '%x%'").delete_all` or `where("email = ?", email).update_all(...)` (Rails puts the value into the SQL) sent the filter with the value in it. Every string value written into the filter is now sent as `'[redacted]'` (numbers, such as ids, are kept); values passed as binds, and the new values of `update_all`, are masked by column, as before. A keyword, comma or `?` inside a quoted value no longer splits the statement.
- **A rolled-back write no longer reads as done (Rails 7.2 and later).** Row changes, bulk writes and the writes below wait on their transaction (Rails' own `after_commit` for it) and are dropped when it rolls back: a failed step later in the transaction, `ActiveRecord::Rollback`, a rolled-back savepoint. Nothing is kept on the records and no callback is added to your models; past 10,000 waiting changes in one transaction the rest go out at once. Older Rails sends them at once, as before.
- **A request Devise stopped for a sign-in (`throw :warden`) reads as a failure** ("sign-in required", 401), and so does a request ended by an exception outside `StandardError` (a request timeout). The throw and the exception reach the app exactly as before.
- **Two ActiveJob runs of one class in an action stay two:** each job's `job_id` and retry number are sent, so one job's failure is never hidden by another's success.
- **Writes that skip callbacks are recorded:** `update_column` and `update_columns` (with what changed) and `record.delete` (as a deletion).
- **Schema-per-tenant and sharded apps keep tenants apart:** a record's id carries its tenant (`acme:5`) on a shard other than the model's default shard, or under an Apartment schema tenant (PostgreSQL schemas; never for Apartment's excluded models or a schema-qualified table, which every tenant shares; a database-per-tenant setup keeps plain ids, since reading its tenant would cost a query per row). Row changes, jobs and requests use the same rule. An app that uses neither keeps its ids unchanged.
- Works with `ActiveRecord.permanent_connection_checkout = :disallowed` (the model's connection is used through `with_connection`).
- **Signing in, signing out and resetting a password are recorded.** Only loading those pages (GET, HEAD) is left out, as in ezlogs-nextjs, and only whole path segments match, so `/sessions/42/book` or `/admin/users/5/login_as` are no longer hidden.
- **GraphQL is read wherever the app mounts it** (`/api/graphql`, `/api/v1/graphql`), not only at `/graphql`: its operation name, and errors returned with status 200 as failures.
- **An inbound email (Action Mailbox) is recorded without the email:** its request params (the whole raw message) are never sent.
- **A bulk write names the exact model** Active Record named the query after, so single-table inheritance and two models on one table read right.
- **Outside calls through Typhoeus and Excon** are recorded as steps too (beside Net::HTTP, which Faraday uses by default, and http.rb), with the same rules: domain, method, path pattern, status, time.
- **An excluded job sends nothing,** its database writes included (as an excluded path): they were stored with no action and never shown.
- **Action Cable channel actions are actions.** Their writes ran outside any request and were stored but never shown; each channel action is now one action, named by the connection's person (your `actor_from_request`, called with the connection's request).
- **Solid Queue recurring tasks given as a `command:`** are captured (they run inside `SolidQueue::RecurringJob`, which was left out), so their writes form an action.
- **The same secret names as every EZLogs agent:** `passcode`, `cardnumber`, and (new everywhere) one-time and recovery codes (`verification_code`, `recovery_code`, `backup_code`, `one_time_code`, `login_code`) and the word `jti`.
- **A busy moment is never lost whole.** Events go out in posts of at most about 1 MB (the server refuses a post over 5 MB, and with it every event inside), strings over 4 KB are cut with a note of their length (a long text column, a raw email), and a post the server refuses (4xx other than 408 and 429) is not sent again.
- **A job run more than an hour after its action started is its own action** (a job delayed by days, a late retry), never part of one dated days earlier.
- **A page loaded only in case it is opened is no longer a visit.** Turbo 8 prefetches a link when the pointer rests on it (`X-Sec-Purpose: prefetch`), and browsers prefetch or prerender (`Sec-Purpose`, `Purpose`): those GET and HEAD requests record no request. Writes they make, if any, are still recorded. ezlogs-nextjs already skips them.

## [0.2.10] — 2026-11-21

### Changed
- **Records are named the same way in every EZLogs agent.** Without `display_name_for`, a record is named by its `name`, `title`, `number`, then (new) `label` or `<model>_number` (`invoice_number`), the same chain as ezlogs-nextjs and the Supabase install. A record with none shows by its short id (`#42`, `#b38a…a236`).
- Docs and the generated initializer no longer suggest an email as a record's name: names show on shared links.

## [0.2.9] — 2026-11-21

### Changed
- **Outside calls keep less of the path.** The first path segment is kept only when it is on a fixed list of about 100 common API collection names (`charges`, `customers`, `messages`, `payment_intents`, …). Before, any lowercase word that looked plural passed, so a name ending in "s" (`/charles`) could leave the app. Anything else is now `:id`, and the action page reads "Called example.com".

## [0.2.8] — 2026-11-21

### Added
- **Calls to outside services show up.** An HTTP call your app makes (Net::HTTP, so Faraday's default adapter, HTTParty, RestClient, the Stripe and Anthropic gems; and the `http` gem) and an email ActionMailer delivers (SMTP or an API) are recorded as steps of the action that made them, named on the action page ("Created a checkout session at stripe.com", "Sent the “feedback received” email via resend.com"). A failed one ("…, but the call to slack.com failed") makes the action partly failed and gives its reason.
  - Sent: host, method, the path as a pattern (anything that isn't a plain word becomes `:id`), status and time; for an email, its mailer and action. Never a body, a query string, a header, a recipient or a subject.
  - Never outside a request, job or console line, never to EZLogs itself. At most 50 calls per action.
  - New options: `config.capture_outbound` (default `true`) and `config.excluded_hosts` (default `[]`).
  - Cost, measured: about 3 µs per call over the correlation header the agent already adds (local kept-alive connection, median of 10,000 calls; memory constant). The call's response body is never read and its error is re-raised untouched. A streamed response is timed to its headers.
- Needs the EZLogs server from 2026-11-21, which accepts `outbound_call` events.

### Changed
- `config.propagate_correlation = false` now only stops the `X-Correlation-ID` header; the hook stays installed while `capture_outbound` is on.

## [0.2.7] — 2026-11-19

### Changed
- **More secret names are hidden.** `pin`, `otp`, `totp`, `iban`, `mfa` and `passphrase` are matched as whole words (so `pin_code` and `mdmUnlockPin`, never `shipping`), the same list as the Next.js agent. camelCase and dashed names match like their snake_case form: `apiKey`, `api-key`, `creditCard`, `cardNumber` are hidden (they were not).

## [0.2.6] — 2026-11-18

### Added
- **Changes made by hand or on a schedule show up.** A database change made outside any request or job (in `rails console`, a rake task, a `rails runner` script, so also cron) had no correlation id: it never formed an action and never showed anywhere. Now each console line that changes data, each rake task and each runner script is one action, named after what ran it: "Rails console (deploy)" (the OS account from `USER`), "rake orders:backfill", "rails runner" (an actor of kind `system` on its database events). Works with IRB and Pry (pry-rails). Inside a request or a job nothing changes. A run longer than 10 minutes continues as a new action with the same name every 10 minutes. A job enqueued there, or captured as a job when run there, is its own action (a task enqueuing thousands of jobs never becomes one huge action; a job EZLogs does not capture joins the run); outgoing HTTP calls carry the run's id as `X-Correlation-ID`, as from a request. Rake tasks that run a job worker (`jobs:work`, `resque:work`, `solid_queue:start`, `good_job:start`, …) are left alone; add your own with the new `config.excluded_rake_tasks`, or turn the whole grouping off with the new `config.capture_commands = false`. Each rake prerequisite is its own action. Work on other threads is not grouped.

### Changed
- **Excluded paths drop only orphan events.** Inside a request on an excluded path, only events with no correlation id are dropped now (0.2.5 dropped everything the request's thread emitted). A job run there (`perform_now`) has its own correlation id and keeps its events.

### Fixed
- A job whose capture was skipped (capture off, excluded class, the Sidekiq adapter) and that raised emitted a failure event with no correlation id. It no longer does.
- A job run inline (Sidekiq::Testing, `perform_now`, a skipped job) no longer clears the correlation of the request or console line that ran it.

## [0.2.5] — 2026-11-18

### Fixed
- **Excluded paths exclude what happens inside them.** A request on an `excluded_paths` path (or a built-in one such as `/health*`) was not captured, but the database writes, bulk operations and job enqueues it made still were, with no correlation id. They could never join an action, so they never showed anywhere and still took up storage. Now, with HTTP capture on, nothing the request's thread emits while it runs is sent, inline jobs included. Jobs it enqueues to a queue are still captured when they run, as their own actions. Not covered: work on other threads, and writes made while a streamed body is sent.

## [0.2.4] — 2026-11-18

### Added
- **Actions across services.** Outgoing `Net::HTTP` calls (also Faraday's default adapter, HTTParty, RestClient) and `http` gem (http.rb) calls carry the current correlation id as `X-Correlation-ID`, and an incoming request adopts it when it is the agents' own format and recent (same rule as `ezlogs-nextjs`). A Rails app calling another Rails or Next.js app with an agent (or the other way) now reads as one action. Never over a header the app set, never to the EZLogs server. The header is removed from the request object after the call. Off with `config.propagate_correlation = false` (also for test suites whose VCR cassettes match on all headers).

### Fixed
- **A refused save is a failure.** A create that renders its `new` view (an update its `edit` view) with status 200 and writes no row showed the form again (older apps, or `render :new` without a status). It was reported as a success; it is now a failure ("Not saved: the form was shown again"), proven from the template actually rendered.
- Sidekiq retries are numbered right. Sidekiq sets `retry_count` to 0 on the first failure, so the first retry was reported as no retry and every later one one too low. `retry_count` now means earlier failed attempts (absent on a first run), as in the Next.js agent.

### Changed
- Clearer config errors: a missing key says to set `EZLOGS_API_KEY` in the environment (not to paste it into the initializer); an empty `server_url` says to remove the line to use the default.

## [0.2.3] — 2026-11-17

### Changed
- **`server_url` is optional.** It defaults to `ENV["EZLOGS_SERVER_URL"]` if set, otherwise `https://app.ezlogs.io`, so the API key (`project_token`) is the only required setting. An explicit `config.server_url` still wins, and the URL is still validated. The generated initializer now shows `server_url` as a commented-out override. Existing initializers that set `server_url` keep working unchanged.
- An empty `EZLOGS_SERVER_URL` counts as unset. Setting `config.server_url = nil` (or `""`) explicitly still turns capture off, as before. If you run your own EZLogs server, set `EZLOGS_SERVER_URL` (or `config.server_url`): without it the agent now sends to app.ezlogs.io.

## [0.2.2] — 2026-11-17

### Added
- **Startup line.** Each process logs one line, whatever the agent's `log_level` (visible unless Rails' own log level is above `info`), so you can check the install: `[EzLogsAgent] capturing → app.ezlogs.io (key ezl_a1b2c3d4…)`. The key is shown as Settings → API Keys shows it (`ezl_` + first 8 characters); other token shapes get no hint. With config missing it logs `[EzLogsAgent] not capturing: project_token missing`. Silent in the test env. In development it is in `log/development.log`.

### Fixed
- **Events lost at process exit.** `FlushScheduler.stop` (run from `at_exit`) now sends what is still buffered: one attempt, no retries, 1 s HTTP timeouts and a 3 s hard cap. Before, the last up-to-3 s of events (the `send_interval` default) were dropped whenever a process exited: always for `rails runner` / rake tasks, and on every Puma/Sidekiq restart. It also runs when the flush thread had crashed. Shutdown may take up to ~3–5 s longer when events are pending and the server is slow or unreachable.
- **Forked children no longer resend the parent's events.** The buffer inherited across `fork` (Puma cluster workers, etc.) is cleared in the child; the parent still sends it.

### Changed
- **`project_token` is required.** A missing token is now a configuration error and the agent stays off. Before, it was a warning: the agent ran and every batch was rejected with 401. Set the token in `config/initializers/ez_logs_agent.rb`: it is checked once at boot, so a token set later in `after_initialize` or `to_prepare` is not seen.

## [0.2.1] — 2026-06-05

### Fixed
- **Bulk-op row counts on Postgres.** The PG adapter does not populate
  `payload[:row_count]` for plain `DELETE`/`UPDATE` notifications, so
  the first 0.2.0 builds shipped `row_count: 0` for the cases that
  matter most. `BulkDatabaseCapturer` now prepends a tiny shim onto
  `ActiveRecord::Relation#delete_all` / `#update_all` that stashes the
  returned row count and back-fills it onto the just-pushed event via
  `Buffer.peek_last`. No change to the wire shape — `row_count` now
  carries the real number.
- **Model resolution in Rails dev mode.** `ActiveRecord::Base.descendants`
  only sees eager-loaded models. The resolver now falls through to
  `safe_constantize` of the classified table name and verifies the
  reconstructed class actually owns that table, so bulk ops on
  lazy-autoloaded models in dev / test no longer silently drop.
- **Rails Query Log Tags noise in `where_template`.** The parser now
  strips `/*application='X',action='Y'*/` comments before extracting
  the WHERE clause, so the humanized filter line on the server reads
  cleanly instead of leaking the framework's instrumentation tags.

### Changed
- **Framework-rewrite filter narrowed.** The 0.2.0 filter that swallowed
  Rails-generated `SET col = NULL` writes was too aggressive — it also
  hid deliberate "null this column out" operations the customer wrote.
  The filter now only drops `COALESCE`-shaped counter bumps and
  empty-`SET` shells; honest `SET col = NULL` writes are captured and
  render as "Cleared col" on the timeline.
- **Hot-path performance.** `capture_jobs`, `capture_database`, the
  excluded-tables / excluded-job-classes / display-name maps, and the
  user-extended sensitive-key patterns are now memoized at install
  time across `ActiveJobCapturer`, `DatabaseCapturer`,
  `BulkDatabaseCapturer`, and `SensitivePatterns`. The
  `sql.active_record` subscriber is also tuned: 5-arity block to avoid
  splat allocation, cheap `end_with?` name-prefilter ahead of any
  parsing, and an early bail before `safe_constantize`. Bulk capture
  overhead measured below the noise floor on a 10 ms reference query.

## [0.2.0] — 2026-06-05

### Added
- **Bulk database operations are now captured.** Adds a fourth event
  `source_type` — `bulk_database` — for the four ActiveRecord operations
  that bypass per-row callbacks: `delete_all`, `update_all`, `insert_all`,
  `upsert_all`. Implemented via a narrowly-filtered
  `ActiveSupport::Notifications.subscribe("sql.active_record")` subscription
  (`Capturers::BulkDatabaseCapturer`) — not a replacement for the existing
  callback-based DatabaseCapturer; the two run side by side under the
  same `capture_database` config flag.

  The new wire shape carries `model_class`, `operation`, `row_count`,
  `where_template` + sanitized `where_binds`, plus an operation-specific
  field (`set` for update_all, `columns` for insert_all/upsert_all).
  Insert/upsert ship column NAMES only — no values, per the product
  decision that bulk-row PII shouldn't ride the wire.

  Cascade case (`dependent: :delete_all` on a parent destroy) is
  captured automatically, since it produces the same SQL shape — the
  reader sees the parent destroy AND the cascade as sibling rows on the
  timeline.

  Resource attribution uses a `resource_id: "bulk:<row_count>"` sentinel,
  since individual row IDs are not knowable from the SQL without
  changing the customer's operation (which would violate the read-only
  principle).

### Changed
- `Sanitizer::SENSITIVE_PATTERNS` and the previous in-class
  `DatabaseCapturer::SENSITIVE_PATTERNS` (which had drifted) are now a
  single source of truth: `EzLogsAgent::SensitivePatterns::PATTERNS`.
  Both capturers + the new BulkDatabaseCapturer consult the same list.
  The merged list is the UNION of the previous two — no patterns
  removed; `passwd`, `pwd`, `cvv`, `cvc`, `pem`, `cipher`, `nonce`,
  `salt`, `digest`, `signature`, `hmac` all continue to be masked.
- `encrypts :foo` introspection (Rails 7+ `model.class.encrypted_attributes`)
  is now exposed as the standalone `EzLogsAgent::EncryptedAttributes`
  module, so both the per-row and bulk capturers consult it via the
  same path. Behavior unchanged for per-row.

### Limits (documented)
- Raw `connection.execute(sql)` calls are not captured (no
  notifications fire under `sql.active_record` with a recognizable
  shape). Use the typed bulk methods to get visibility.
- Specific row IDs affected by a bulk op are not captured — only the
  filter rule (WHERE columns + values) and row count. For per-row
  detail, use `find_each(&:destroy)` style which fires per-row
  callbacks.

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
