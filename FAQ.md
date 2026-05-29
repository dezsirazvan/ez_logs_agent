# EZLogs Agent — Frequently Asked Questions

Common questions about EZLogs Agent.

---

## General

### What is EZLogs?

EZLogs transforms technical system activity into human-readable stories that anyone on your team can understand.

Instead of scattered logs across multiple tools, you see complete activity stories:
- What happened
- Who triggered it
- What succeeded or failed
- All in plain language

See [README.md](README.md) for the full overview.

---

### How is EZLogs different from Datadog/New Relic/CloudWatch?

**EZLogs is for understanding. Monitoring tools are for debugging.**

| Tool | Purpose | Audience |
|------|---------|----------|
| **EZLogs** | What happened in the system (business understanding) | Everyone (support, product, founders) |
| **Datadog** | Performance monitoring, metrics, traces | Engineers |
| **New Relic** | APM, performance bottlenecks | Engineers |
| **CloudWatch** | Infrastructure monitoring, logs | Engineers, DevOps |

EZLogs complements these tools—it doesn't replace them. Engineers still use monitoring tools for debugging. EZLogs lets everyone else understand what's happening.

---

### Is EZLogs an audit log?

**No.** EZLogs is best-effort, not guaranteed delivery.

For compliance and legal requirements, use:
- **PaperTrail** — Audit trail gem for Rails
- **Audited** — ActiveRecord auditing
- **LogDNA/Loggly** — Compliant log aggregation

EZLogs prioritizes understanding over completeness. Some events may be dropped if the server is unreachable. This is intentional.

---

### Can I use EZLogs for compliance (SOC 2, HIPAA, etc.)?

**No.** EZLogs is not designed for compliance requirements.

Compliance requires:
- Guaranteed event delivery
- Immutable logs
- Long-term retention
- Tamper-proof storage

EZLogs is best-effort and designed for operational visibility, not legal compliance.

---

## Installation & Setup

### What are the requirements?

- **Ruby** >= 3.1.0
- **Rails** application (any recent version)
- **Sidekiq** or **ActiveJob** (optional, for job capture)
- **ActiveRecord** (optional, for database capture)

That's it. No other dependencies.

---

### Do I need to modify my application code?

**No.** EZLogs Agent self-configures via Rails Railtie.

Just:
1. Add the gem
2. Run the generator
3. Configure server URL and API key
4. Restart your app

No code changes, no middleware registration, no monkey patching required.

---

### Will EZLogs slow down my application?

**No.** The agent is designed to be invisible:

- **Event capture:** Synchronous but extremely fast (microseconds)
- **Sending events:** Asynchronous via background thread (zero latency added to requests)
- **Memory:** ~1-2MB for default buffer size

**Performance impact:** Negligible. You won't notice it.

---

###Can I use this in production?

**Yes.** EZLogs Agent is production-ready:

- 685+ tests covering all scenarios
- Comprehensive error handling
- Never blocks or crashes your application
- Fails gracefully if server is unreachable

It's designed to be safe and reliable.

---

## Behavior & Data

### Are events guaranteed to be delivered?

**No.** EZLogs is best-effort, not guaranteed delivery.

Events may be dropped if:
- EZLogs server is unreachable
- Network connection fails after retries
- Buffer overflows (too many events)

**This is intentional.** Your application's reliability is more important than capturing every event.

---

### Can events arrive out of order?

**Yes.** Events are sent asynchronously and may arrive out of order.

EZLogs Server uses timestamps to reconstruct the correct timeline, but there's no strict ordering guarantee.

---

### What happens if events are dropped?

**Your application continues normally.** Dropped events are logged as warnings:

```
[EzLogsAgent] Buffer full, dropping oldest events
[EzLogsAgent] Failed to send events after 3 retries, dropping batch
```

You'll see gaps in your activity log, but your app keeps running.

---

### How long does correlation last?

**Correlation lasts for the lifetime of a user action.**

Example:
1. HTTP request generates `correlation_id: "req_abc123"`
2. Background jobs enqueued from that request inherit `"req_abc123"`
3. Database changes within those jobs also get `"req_abc123"`
4. Jobs enqueued from those jobs also inherit `"req_abc123"`

**Correlation ends when:**
- Jobs complete
- Cron jobs start (new correlation)
- Console operations (no correlation)

---

### What if correlation is missing?

**This is expected and acceptable.**

Some events have no correlation:
- Cron jobs
- Console operations
- Database callbacks outside request/job context

These events still appear in your log—they just won't be grouped with other events.

**Design principle:** Missing data is acceptable; wrong data is not. The agent never guesses correlation IDs.

---

## Data & Privacy

### What data does EZLogs capture?

**HTTP requests:**
- Method, path, status code, duration
- Controller and action name
- GraphQL operation name (queries, mutations, subscriptions)
- Request parameters (sanitized)

**Background jobs:**
- Job class, queue, duration
- Success/failure status
- Error message (if failed)
- Job arguments (sanitized)

**Database changes:**
- Model class, record ID, operation type
- Attribute changes (for updates)

**NOT captured:**
- Request bodies (except params)
- Response bodies
- Session data
- Cookies
- SELECT queries

---

### Does EZLogs capture request bodies?

**No, not directly.** Only request parameters are captured (e.g., `params` hash in Rails).

**Sanitization:** Sensitive parameters are automatically redacted:
- `password`
- `token`
- `secret`
- `api_key`
- `credit_card`

See [README.md#what-gets-captured](README.md#what-gets-captured) for details.

---

### Does EZLogs capture database field values?

**Only for updates, and only one meaningful field.**

For updates, the agent captures one attribute change:
- `status: pending → shipped`
- `email: old@example.com → new@example.com`

This is enough to understand what changed without capturing all data.

**NOT captured:**
- All field values
- Sensitive fields (password, token, etc.)
- Binary data

---

### How do I prevent sensitive data from being sent?

**1. Exclude sensitive paths:**
```ruby
config.excluded_paths = ["/admin*", "/internal*"]
```

**2. Exclude sensitive tables:**
```ruby
config.excluded_tables = ["credit_cards", "ssn_data"]
```

**3. Disable specific capture types:**
```ruby
config.capture_database = false  # Don't capture DB changes
```

**4. Sensitive params are auto-redacted:**
The agent automatically redacts params named:
- `password`, `token`, `secret`, `api_key`, `credit_card`

---

## Performance

### What's the memory overhead?

**Default configuration:** ~1-2MB

This is from the event buffer (10,000 events by default).

**To reduce (low-volume apps):**
```ruby
config.buffer_size = 5000  # ~500KB-1MB
```

**To increase (very high-traffic apps):**
```ruby
config.buffer_size = 20000  # ~2-4MB
```

---

### How many events can be buffered?

**Default:** 10,000 events

When the buffer is full, oldest events are dropped (circular buffer).

**To adjust:**
```ruby
config.buffer_size = 20000  # For very high-volume apps
```

---

### Will this cause memory leaks?

**No.** The buffer is fixed-size and circular.

Memory usage is bounded by:
```
memory = buffer_size × average_event_size
```

Even if events aren't sent (server down), memory won't grow unbounded.

---

### What if my app generates millions of events?

**The agent is designed for this:**

1. **Buffer overflow protection** — Oldest events are dropped when buffer is full
2. **Batched sending** — Events sent every 3 seconds by default (configurable)
3. **Async processing** — Never blocks your application

**Default settings already optimized for high-volume.** To tune further:
```ruby
config.buffer_size = 20000      # Even larger buffer (if needed)
config.send_interval = 2        # Even more frequent sends
config.excluded_paths = [...]   # Filter noise
```

---

## Configuration

### Do I need to configure actor context?

**No, it's optional.**

Without actor context, events are captured with `actor: null`. You'll still see what happened, just not who triggered it.

**When to configure it:**
- You want to know who triggered each action
- You have user authentication (Devise, Clearance, custom)
- Attribution matters for your use case

See [CONFIGURATION.md#actor-context](CONFIGURATION.md#actor-context) for setup.

---

### How do I exclude sensitive paths?

```ruby
config.excluded_paths = ["/admin*", "/internal*"]
```

Use `*` suffix for prefix matching:
- `/admin*` matches `/admin`, `/admin/users`, etc.

See [CONFIGURATION.md#excluded_paths](CONFIGURATION.md#excluded-paths) for details.

---

### What happens if EZLogs server is down?

**Your application continues running normally.**

The agent:
1. Retries sending (with exponential backoff)
2. Logs warnings
3. Drops events after max retries
4. Never crashes or blocks your app

**Your app is always the priority.**

---

### Can I send events to multiple servers?

**No, not directly.** The agent only supports one `server_url`.

**Workarounds:**
- Run multiple Rails instances with different configs
- Use a load balancer to route to multiple EZLogs servers
- Contact support@ezlogs.com for enterprise multi-region setups

---

## Debugging

### How do I know if it's working?

**Run the connection test:**
```bash
rails ez_logs_agent:test_connection
```

This verifies:
- Configuration is valid
- Server is reachable
- Authentication works
- Events are being accepted

---

### Where can I see agent errors?

**Check Rails logs:**
```
[EzLogsAgent] Agent initialized successfully
[EzLogsAgent] Sending batch of 5 events...
[EzLogsAgent] Batch sent successfully (HTTP 200)
```

**For errors:**
```
[EzLogsAgent] Failed to send events (HTTP 401)
[EzLogsAgent] Failed to send events (timeout)
```

---

### How do I enable debug logging?

```ruby
# config/initializers/ez_logs_agent.rb
config.log_level = :debug
```

Then restart Rails. You'll see detailed output:
```
[EzLogsAgent] Captured HTTP event: GET /users (200, 45ms)
[EzLogsAgent] Captured Database event: User#create (id: 123)
[EzLogsAgent] Buffer: 12 events
[EzLogsAgent] Sending batch of 12 events...
```

**Warning:** Debug mode is verbose. Use it for troubleshooting only.

---

### Events aren't showing up. What do I check?

1. **Run connection test:**
   ```bash
   rails ez_logs_agent:test_connection
   ```

2. **Check Rails logs** for agent messages

3. **Enable debug logging:**
   ```ruby
   config.log_level = :debug
   ```

4. **Verify configuration:**
   - `server_url` is correct
   - `project_token` is valid
   - Rails was restarted after config changes

See [README.md#troubleshooting](README.md#troubleshooting) for detailed steps.

---

## Compatibility

### Does this work with Rails API-only apps?

**Yes.** The agent works with Rails API-only mode.

- HTTP capture: ✅ Works
- Job capture: ✅ Works
- Database capture: ✅ Works
- Actor context: ⚠️ Requires custom extraction (no `controller.current_user`)

---

### Does this work with Grape/Sinatra/other Rack apps?

**Partially.** The agent is designed for Rails but may work with other Rack apps:

- HTTP capture: ✅ Works (Rack middleware)
- Job capture: ✅ Works (if using Sidekiq/ActiveJob)
- Database capture: ✅ Works (if using ActiveRecord)
- Auto-configuration: ❌ No Rails Railtie (manual setup required)

**For non-Rails apps,** contact support@ezlogs.com

---

### Does this work with Resque/Delayed::Job/Que?

**Only Sidekiq and ActiveJob are supported currently.**

Planned future support:
- Resque
- Delayed::Job
- Que

See [docs/agent/roadmap.md](../docs/agent/roadmap.md) for the roadmap.

---

### Does this work with Sequel/ROM/other ORMs?

**No, only ActiveRecord is supported.**

Database capture requires ActiveRecord callbacks.

---

## Pricing & Licensing

### Is EZLogs free?

See pricing at [ezlogs.io/pricing](https://ezlogs.io/pricing)

The agent gem is open-source (MIT license). The hosted EZLogs server is a paid SaaS service.

---

### What's the license?

**MIT License.** See [LICENSE.txt](LICENSE.txt)

You can use EZLogs Agent freely in commercial and open-source projects.

---

### Can I self-host the EZLogs server?

**The server code is in this repository,** but it's not officially supported for self-hosting.

For self-hosting questions, contact support@ezlogs.com

---

## Support

### How do I report a bug?

1. Check [GitHub Issues](https://github.com/your-org/ez_logs/issues) for existing reports
2. Open a new issue with:
   - Clear description
   - Steps to reproduce
   - Expected vs actual behavior
   - Rails version, Ruby version
   - Output of `rails ez_logs_agent:test_connection`

---

### How do I request a feature?

Open a [GitHub Issue](https://github.com/your-org/ez_logs/issues) or start a [GitHub Discussion](https://github.com/your-org/ez_logs/discussions).

---

### Where do I get help?

- **Documentation:** [README.md](README.md), [CONFIGURATION.md](CONFIGURATION.md), [QUICKSTART.md](QUICKSTART.md)
- **GitHub Issues:** [Report bugs and request features](https://github.com/your-org/ez_logs/issues)
- **Email:** support@ezlogs.com (for customers)

---

## Still have questions?

- [README.md](README.md) — Full documentation
- [QUICKSTART.md](QUICKSTART.md) — Getting started guide
- [CONFIGURATION.md](CONFIGURATION.md) — Configuration reference
- [GitHub Issues](https://github.com/your-org/ez_logs/issues) — Report bugs
- [Email support](mailto:support@ezlogs.com) — For customers

---

**Can't find your answer?** [Open an issue](https://github.com/your-org/ez_logs/issues) or email support@ezlogs.com
