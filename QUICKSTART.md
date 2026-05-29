# EZLogs Agent — Quick Start Guide

Get EZLogs running in your Rails application in 5 minutes.

---

## Prerequisites

Before you begin, make sure you have:

- ✅ **Ruby** 3.1.0 or higher
- ✅ **Rails** application (any recent version)
- ✅ **EZLogs account** with an API key ([sign up here](https://app.ezlogs.io))

**Optional but supported:**
- Sidekiq or ActiveJob (for background job capture)
- ActiveRecord (for database change capture)

---

## Step 1: Add the Gem

Add EZLogs Agent to your `Gemfile`:

```ruby
gem 'ez_logs_agent'
```

Then install it:

```bash
bundle install
```

**Expected output:**
```
Fetching ez_logs_agent 0.1.0
Installing ez_logs_agent 0.1.0
Bundle complete!
```

---

## Step 2: Run the Generator

Generate the configuration file:

```bash
rails generate ez_logs_agent:install
```

**What this does:**
- Creates `config/initializers/ez_logs_agent.rb` with all available configuration options
- Adds helpful comments explaining each setting

**Expected output:**
```
      create  config/initializers/ez_logs_agent.rb
```

---

## Step 3: Get Your API Key

1. **Sign up** for EZLogs at [app.ezlogs.io](https://app.ezlogs.io)
2. **Create a company** (happens automatically during registration)
3. **Navigate to Settings** → **API Keys**
4. **Click "Create New API Key"**
5. **Copy the key** (it starts with `ezl_`)

**Important:** Keep your API key secure. Don't commit it to version control.

---

## Step 4: Configure the Agent

The generator already wrote `config/initializers/ez_logs_agent.rb` with sensible defaults — `server_url` points at `https://app.ezlogs.io` (the same URL for every SaaS customer) and `project_token` reads from `ENV["EZLOGS_API_KEY"]`. The only thing you need to set is the API key.

```bash
# .env (development, with the dotenv gem)
EZLOGS_API_KEY=ezl_your_api_key_here

# Production — set via your hosting platform:
# Heroku:  heroku config:set EZLOGS_API_KEY=ezl_...
# Render / Fly / Railway: set in the env-vars dashboard
```

If you self-host the EzLogs server, also set `EZLOGS_SERVER_URL` to your deployment URL — the generated initializer reads it from `ENV["EZLOGS_SERVER_URL"]` automatically.

**Note:** The config setter is called `project_token`, but the value is the API key you copied in Step 3.

---

## Step 5: Test the Connection

Verify everything is configured correctly:

```bash
rails ez_logs_agent:test_connection
```

### ✅ Success Output

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

If you see this, **you're all set!** Skip to Step 6.

### ❌ Failure Output

If the test fails, you'll see what's wrong:

**Example: Invalid API key**
```
❌ Connection failed (HTTP 401 Unauthorized)

Possible causes:
  - Invalid API key (project_token)
  - API key has been revoked
  - Check your project_token in config/initializers/ez_logs_agent.rb
```

**Example: Server unreachable**
```
❌ Connection failed (timeout)

Possible causes:
  - Server URL is incorrect
  - Network connectivity issue
  - Firewall blocking outbound HTTPS
```

**Fix the error** shown in the output and run the test again.

---

## Step 6: Restart Your Application

Restart your Rails server to load the configuration:

```bash
# Stop the server (Ctrl+C)
# Then start it again
rails server

# Or for production deployments, use your platform's restart command
```

### Verify Initialization

Check your Rails logs for the startup message:

```
[EzLogsAgent] Agent initialized successfully
[EzLogsAgent] Server URL: https://app.ezlogs.io
[EzLogsAgent] ✓ HTTP capture enabled
[EzLogsAgent] ✓ Sidekiq capture enabled
[EzLogsAgent] ✓ Database capture enabled
```

If you see this, the agent is running!

---

## Step 7: Generate Activity

Interact with your application to generate events:

1. **Make HTTP requests** — Visit pages, submit forms, trigger API endpoints
2. **Run background jobs** — Trigger jobs that send emails, process data, etc.
3. **Change database records** — Create, update, or delete records

### Example Activities

```ruby
# In Rails console or by using your app

# HTTP request (if you visit a page)
GET /users

# Database change
user = User.create(email: "test@example.com")

# Background job (if configured)
WelcomeEmailJob.perform_later(user)
```

---

## Step 8: View Your Activity Log

1. **Open your EZLogs dashboard** at [app.ezlogs.io](https://app.ezlogs.io)
2. **Navigate to the Timeline** (usually the home page)
3. **See your activity** appear in real-time!

You should see entries like:

```
User created 'test@example.com'
2:34 PM, January 15, 2025

  ✓ User record created
  ✓ Welcome email job enqueued
  ✓ Email sent successfully

Status: Completed
```

---

## Next Steps

Congratulations! EZLogs is now capturing activity from your application.

### Enhance Your Setup

**1. Add Actor Context** (track who triggered each action)

```ruby
EzLogsAgent.configure do |config|
  # ... existing config ...

  config.actor_from_request = ->(env, controller) {
    return nil unless controller.respond_to?(:current_user)
    user = controller.current_user
    return nil unless user

    {
      id: user.id.to_s,
      label: user.email
    }
  }
end
```

See [README.md#actor-context](README.md#actor-context--who-triggered-this) for details.

**2. Configure Display Names** (human-readable resource identifiers)

```ruby
EzLogsAgent.configure do |config|
  # ... existing config ...

  config.display_name_for = {
    "User" => :email,
    "Product" => :name,
    "Order" => :number
  }
end
```

See [README.md#display-names](README.md#display-names--human-readable-resource-identifiers) for details.

**3. Exclude Sensitive Paths**

```ruby
EzLogsAgent.configure do |config|
  # ... existing config ...

  config.excluded_paths = ["/admin*", "/internal*"]
end
```

**4. Customize What Gets Captured**

```ruby
EzLogsAgent.configure do |config|
  # ... existing config ...

  # Disable specific capture types if needed
  config.capture_http = true      # HTTP requests
  config.capture_jobs = true      # Background jobs
  config.capture_database = true  # Database changes
end
```

### Full Configuration Reference

See [CONFIGURATION.md](CONFIGURATION.md) for all available options.

---

## Troubleshooting

### Events Not Showing Up

1. **Run the connection test:**
   ```bash
   rails ez_logs_agent:test_connection
   ```

2. **Check Rails logs** for agent messages:
   ```
   [EzLogsAgent] Sending batch of 5 events...
   [EzLogsAgent] Batch sent successfully (HTTP 200)
   ```

3. **Enable debug logging:**
   ```ruby
   # config/initializers/ez_logs_agent.rb
   config.log_level = :debug
   ```

### Common Issues

| Problem | Solution |
|---------|----------|
| HTTP 401 errors | API key is invalid or revoked. Get a new key from dashboard. |
| Connection timeout | Check `server_url` is correct and server is reachable. |
| No events captured | Verify Rails is restarted after configuration changes. |
| Jobs not captured | Ensure Sidekiq middleware is registered (check logs for `[Railtie] Sidekiq server middleware registered`). |

**For more help:** See [README.md#troubleshooting](README.md#troubleshooting)

---

## FAQ

### Do I need to modify my application code?

**No.** EZLogs Agent self-configures via Rails Railtie. Just add the gem, configure it, and restart. No code changes needed.

### Will this slow down my application?

**No.** Event capture happens asynchronously. Events are buffered in memory and sent in background threads. Zero latency added to requests.

### What if the EZLogs server is down?

**Your app continues normally.** Events are retried a few times, then dropped. The agent never blocks or crashes your application.

### Is my data secure?

**Yes.** Events are sent over HTTPS with Bearer token authentication. Data is scoped to your company with complete isolation.

### Can I use this in production?

**Yes.** EZLogs Agent is production-ready with 685+ tests and comprehensive error handling. It's designed to be invisible to your application.

### How much does it cost?

See pricing at [ezlogs.io/pricing](https://ezlogs.io/pricing)

---

## Support

- **Documentation:** [README.md](README.md)
- **Configuration:** [CONFIGURATION.md](CONFIGURATION.md)
- **FAQ:** [FAQ.md](FAQ.md)
- **Issues:** [GitHub Issues](https://github.com/your-org/ez_logs/issues)
- **Email:** support@ezlogs.com

---

**You're all set! 🎉**

Your application is now sending activity to EZLogs. Everyone on your team can now understand what's happening in your system—no engineer required.
