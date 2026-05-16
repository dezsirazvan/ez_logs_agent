# frozen_string_literal: true

require "rails/generators/base"

module EzLogsAgent
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates an EzLogsAgent initializer with all configuration options"

      def show_welcome_message
        say "\n"
        say "=" * 70, :green
        say "  EzLogs Agent Installation", :green
        say "=" * 70, :green
        say "\n"
      end

      def detect_environment
        @sidekiq_detected = defined?(Sidekiq)
        @activejob_detected = defined?(ActiveJob)
        @activerecord_detected = defined?(ActiveRecord)
        @devise_detected = defined?(Devise)

        say "Detected Components:", :cyan
        rails_version = defined?(Rails::VERSION::STRING) ? Rails::VERSION::STRING : "unknown"
        say "  • Rails #{rails_version}"
        say "  • Sidekiq #{Sidekiq::VERSION}", :green if @sidekiq_detected
        say "  • ActiveJob", :green if @activejob_detected && !@sidekiq_detected
        say "  • ActiveRecord", :green if @activerecord_detected
        say "  • Devise", :green if @devise_detected
        say "\n"
      end

      def create_initializer_file
        initializer_path = File.join(destination_root, "config/initializers/ez_logs_agent.rb")

        if File.exist?(initializer_path)
          say "⚠️  Initializer already exists at config/initializers/ez_logs_agent.rb", :yellow
          say "   Skipping creation to avoid overwriting your existing configuration.", :yellow
          say "\n"
          return
        end

        template "ez_logs_agent.rb.tt", "config/initializers/ez_logs_agent.rb"
        say "\n"
        say "✅ Created config/initializers/ez_logs_agent.rb", :green
        say "\n"
      end

      def show_next_steps
        say "=" * 70, :cyan
        say "  Next Steps", :cyan
        say "=" * 70, :cyan
        say "\n"

        say "1. Get your API key from EzLogs:", :bold
        say "   → Log in to your EzLogs dashboard"
        say "   → Go to Settings → API Keys"
        say "   → Create a new API key for this application\n\n"

        say "2. Configure the agent:", :bold
        say "   → Open config/initializers/ez_logs_agent.rb"
        say "   → Set your server_url (e.g., https://app.ezlogs.io)"
        say "   → Set your project_token (the API key from step 1)\n\n"

        if @devise_detected
          say "3. Enable actor tracking (optional but recommended):", :bold
          say "   → Uncomment the actor_from_request block"
          say "   → The Devise example is already configured for you\n\n"
        else
          say "3. Enable actor tracking (optional):", :bold
          say "   → Uncomment the actor_from_request block in the initializer"
          say "   → Customize it for your authentication system\n\n"
        end

        say "4. Test the connection:", :bold
        say "   → Run: rails ez_logs_agent:test_connection"
        say "   → This verifies your configuration is correct\n\n"

        say "5. Restart your Rails server:", :bold
        say "   → The agent will start capturing events automatically"
        say "   → Check your EzLogs dashboard to see activity\n\n"

        say "=" * 70, :cyan
        say "\n"

        say "Need help? Check the README or visit https://docs.ezlogs.io", :cyan
        say "\n"
      end
    end
  end
end
