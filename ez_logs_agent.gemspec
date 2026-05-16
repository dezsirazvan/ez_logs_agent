# frozen_string_literal: true

require_relative "lib/ez_logs_agent/version"

Gem::Specification.new do |spec|
  spec.name = "ez_logs_agent"
  spec.version = EzLogsAgent::VERSION
  spec.authors = ["dezsirazvan"]
  spec.email = ["dezsirazvan@gmail.com"]

  spec.summary = "Captures Rails application activity for EzLogs"
  spec.description = "Captures HTTP requests, background jobs, and database changes from Rails applications. Events are automatically correlated and sent to EzLogs Server, where they are transformed into human-readable activity stories."
  spec.homepage = "https://github.com/dezsirazvan/ez_logs_agent"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/dezsirazvan/ez_logs_agent"
  spec.metadata["changelog_uri"] = "https://github.com/dezsirazvan/ez_logs_agent/blob/master/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/dezsirazvan/ez_logs_agent/issues"
  spec.metadata["documentation_uri"] = "https://github.com/dezsirazvan/ez_logs_agent#readme"

  # Files shipped inside the .gem on rubygems. Allowlist (not blocklist) so
  # the package stays small and predictable: code + the docs customers
  # actually need (README, LICENSE, CHANGELOG). Long-form docs
  # (CONFIGURATION/FAQ/QUICKSTART/RELEASING) live on the public repo
  # only — rubygems renders the README and that's what installers see.
  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.{rb,tt}"] +
      %w[README.md LICENSE.txt CHANGELOG.md]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "request_store", "~> 1.5"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "webmock", "~> 3.18"
  spec.add_development_dependency "rack", "~> 2.2"
  spec.add_development_dependency "sidekiq", "~> 7.0"
  spec.add_development_dependency "rails", "~> 7.0"
  spec.add_development_dependency "sqlite3", "~> 1.6"
end
