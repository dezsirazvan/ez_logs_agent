# frozen_string_literal: true

namespace :ez_logs_agent do
  desc "Test connection to EzLogs server"
  task test_connection: :environment do
    require "ez_logs_agent"

    puts "\n🔍 EzLogs Agent Connection Test\n\n"

    # Step 1: Validate configuration
    puts "Step 1: Validating configuration..."
    result = EzLogsAgent::ConfigurationValidator.validate(EzLogsAgent.configuration)

    if result.errors.any?
      puts "❌ Configuration validation failed:\n"
      result.errors.each do |error|
        puts "  - #{error}"
      end
      puts "\n"
      exit 1
    end

    if result.warnings.any?
      puts "⚠️  Configuration warnings:\n"
      result.warnings.each do |warning|
        puts "  - #{warning}"
      end
      puts "\n"
    end

    puts "✅ Configuration is valid\n\n"

    # Step 2: Show configuration summary
    config = EzLogsAgent.configuration
    puts "Configuration Summary:"
    puts "  Server URL: #{config.server_url}"
    puts "  Project Token: #{config.project_token ? '***' + config.project_token[-4..-1] : '(not set)'}"
    puts "  Capture HTTP: #{config.capture_http}"
    puts "  Capture Jobs: #{config.capture_jobs}"
    puts "  Capture Database: #{config.capture_database}"
    puts "\n"

    # Step 2: Test connection
    puts "Step 2: Testing connection to server..."

    begin
      uri = URI.parse(config.server_url)
      uri.path = "/api/events" if uri.path.empty?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10

      # Send a test event
      test_event = {
        kind: "test",
        correlation_id: "test_connection_#{Time.now.to_i}",
        occurred_at: Time.now.utc.iso8601(3),
        context: {
          message: "EzLogs Agent connection test",
          source: "rake ez_logs_agent:test_connection"
        }
      }

      request = Net::HTTP::Post.new(uri.path)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{config.project_token}" if config.project_token
      request.body = { events: [test_event] }.to_json

      response = http.request(request)

      case response.code.to_i
      when 200..299
        puts "✅ Connection successful (HTTP #{response.code})"
        puts "   Test event accepted by server\n\n"
        puts "✅ All checks passed! EzLogs Agent is configured correctly.\n\n"
        exit 0
      when 401
        puts "❌ Authentication failed (HTTP 401)"
        puts "   Check your project_token in config/initializers/ez_logs_agent.rb\n\n"
        exit 1
      when 404
        puts "❌ Server endpoint not found (HTTP 404)"
        puts "   Check your server_url: #{config.server_url}\n\n"
        exit 1
      else
        puts "❌ Server responded with HTTP #{response.code}"
        puts "   Response: #{response.body[0..200]}\n\n"
        exit 1
      end
    rescue SocketError => e
      puts "❌ Could not resolve host: #{e.message}"
      puts "   Check your server_url: #{config.server_url}\n\n"
      exit 1
    rescue Errno::ECONNREFUSED => e
      puts "❌ Connection refused: #{e.message}"
      puts "   Is the EzLogs server running at #{config.server_url}?\n\n"
      exit 1
    rescue Timeout::Error => e
      puts "❌ Connection timeout: #{e.message}"
      puts "   The server is not responding. Check firewall rules.\n\n"
      exit 1
    rescue StandardError => e
      puts "❌ Connection failed: #{e.class} - #{e.message}"
      puts "   #{e.backtrace.first}\n\n"
      exit 1
    end
  end
end
