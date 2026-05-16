#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates wire-format parity fixtures for cross-language agent testing.
#
# This script drives EzLogsAgent::EventBuilder.build with deterministic
# inputs (frozen time, stable correlation_id) and writes the resulting
# event hashes to spec/fixtures/parity/*.json.
#
# Those fixtures are the contract: the Node agent (@ezlogs/nextjs) ships
# byte-identical events when given equivalent inputs. Run this script
# whenever the wire format changes; commit both the script's diff and
# the regenerated fixtures.
#
# Usage:
#   bundle exec ruby bin/generate_parity_fixtures.rb
#
# Output:
#   spec/fixtures/parity/<scenario>.json — one JSON file per scenario.
#   The Node parity tests read these directly.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ez_logs_agent"
require "json"
require "fileutils"

OUTPUT_DIR = File.expand_path("../spec/fixtures/parity", __dir__)
FIXED_TIMESTAMP = "2026-01-15T12:00:00.000Z"
FIXED_CORRELATION_ID = "ezl_1737000000000_deadbeef"

FileUtils.mkdir_p(OUTPUT_DIR)

def write_fixture(name, event)
  path = File.join(OUTPUT_DIR, "#{name}.json")
  File.write(path, JSON.pretty_generate(event) + "\n")
  puts "  wrote #{name}.json"
end

puts "Generating wire-format parity fixtures..."
puts "  timestamp:      #{FIXED_TIMESTAMP}"
puts "  correlation_id: #{FIXED_CORRELATION_ID}"
puts "  output:         #{OUTPUT_DIR}"
puts

# ---- HTTP scenarios ----

write_fixture "http_get_simple", EzLogsAgent::EventBuilder.build(
  source_type: "http_request",
  source_data: {
    method: "GET",
    path: "/api/users",
    status_code: 200,
    controller: "app/api/users",
    action: "GET",
    format: "json",
    user_agent: "Mozilla/5.0",
    remote_ip: "127.0.0.1"
  },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: nil,
  duration_ms: 124,
  timestamp: FIXED_TIMESTAMP
)

write_fixture "http_post_with_params_sanitized", EzLogsAgent::EventBuilder.build(
  source_type: "http_request",
  source_data: {
    method: "POST",
    path: "/api/users",
    status_code: 201,
    controller: "app/api/users",
    action: "POST",
    format: "json",
    user_agent: "Mozilla/5.0",
    remote_ip: "127.0.0.1",
    request_params: {
      "email" => "alice@example.com",
      "password" => "hunter2",
      "api_key" => "sk_live_xxx",
      "name" => "Alice"
    }
  },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: { actor: { id: "42", label: "alice@example.com" } },
  duration_ms: 230,
  timestamp: FIXED_TIMESTAMP
)

write_fixture "http_failure_4xx", EzLogsAgent::EventBuilder.build(
  source_type: "http_request",
  source_data: {
    method: "GET",
    path: "/api/widgets/missing",
    status_code: 404,
    controller: "app/api/widgets/[id]",
    action: "GET",
    format: "json",
    user_agent: "curl/8.4.0",
    remote_ip: "203.0.113.7"
  },
  outcome: "failure",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: nil,
  duration_ms: 12,
  error_message: "HTTP 404",
  timestamp: FIXED_TIMESTAMP
)

write_fixture "http_failure_exception", EzLogsAgent::EventBuilder.build(
  source_type: "http_request",
  source_data: {
    method: "POST",
    path: "/api/orders",
    status_code: 500,
    controller: "app/api/orders",
    action: "POST",
    format: "json",
    user_agent: "Mozilla/5.0",
    remote_ip: "10.0.0.5"
  },
  outcome: "failure",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: nil,
  duration_ms: 88,
  error_message: "RuntimeError: payment provider unreachable",
  timestamp: FIXED_TIMESTAMP
)

# ---- Database scenarios ----

write_fixture "db_create", EzLogsAgent::EventBuilder.build(
  source_type: "database_callback",
  source_data: { model_class: "User", operation: "create" },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [{ resource_type: "User", resource_id: "42" }],
  context: {
    initial_attributes: {
      "email" => "alice@example.com",
      "name" => "Alice",
      "role" => "customer"
    },
    display_name: "alice@example.com"
  },
  duration_ms: nil,
  timestamp: FIXED_TIMESTAMP
)

write_fixture "db_create_filters_sensitive", EzLogsAgent::EventBuilder.build(
  source_type: "database_callback",
  source_data: { model_class: "User", operation: "create" },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [{ resource_type: "User", resource_id: "43" }],
  context: {
    initial_attributes: {
      "email" => "bob@example.com",
      "password_hash" => "$argon2id$...",
      "api_key" => "sk_live_yyy",
      "name" => "Bob"
    },
    display_name: "bob@example.com"
  },
  duration_ms: nil,
  timestamp: FIXED_TIMESTAMP
)

write_fixture "db_update_with_changes", EzLogsAgent::EventBuilder.build(
  source_type: "database_callback",
  source_data: { model_class: "Order", operation: "update" },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [{ resource_type: "Order", resource_id: "1001" }],
  context: {
    changes: [
      { attribute: "status", from: "pending", to: "shipped" },
      { attribute: "tracking_number", from: nil, to: "1Z999AA10123456784" }
    ],
    display_name: "ORD-1001"
  },
  duration_ms: nil,
  timestamp: FIXED_TIMESTAMP
)

write_fixture "db_destroy", EzLogsAgent::EventBuilder.build(
  source_type: "database_callback",
  source_data: { model_class: "Cart", operation: "destroy" },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [{ resource_type: "Cart", resource_id: "777" }],
  context: { display_name: "Cart #777" },
  duration_ms: nil,
  timestamp: FIXED_TIMESTAMP
)

# ---- Background-job scenarios ----

write_fixture "job_success", EzLogsAgent::EventBuilder.build(
  source_type: "background_job",
  source_data: {
    job_class: "ChargeCardJob",
    job_id: "01J9XYZ12345",
    queue: "default",
    retry_count: 0
  },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: nil,
  duration_ms: 412,
  timestamp: FIXED_TIMESTAMP
)

write_fixture "job_failure", EzLogsAgent::EventBuilder.build(
  source_type: "background_job",
  source_data: {
    job_class: "SendEmailJob",
    job_id: "01J9XYZABCDE",
    queue: "mailers",
    retry_count: 2
  },
  outcome: "failure",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: nil,
  duration_ms: 1503,
  error_message: "Net::SMTPAuthenticationError: 535 Authentication failed",
  timestamp: FIXED_TIMESTAMP
)

# ---- Sanitization edge case: nested + array ----

write_fixture "sanitize_nested_and_array", EzLogsAgent::EventBuilder.build(
  source_type: "http_request",
  source_data: {
    method: "POST",
    path: "/api/keys/rotate",
    status_code: 200,
    request_params: {
      "user" => {
        "email" => "carol@example.com",
        "credit_card" => "4242424242424242"
      },
      "tokens" => [
        { "name" => "ci", "secret" => "wow" },
        { "name" => "prod", "secret" => "such-secret" }
      ]
    }
  },
  outcome: "success",
  correlation_id: FIXED_CORRELATION_ID,
  resource_ids: [],
  context: nil,
  duration_ms: 50,
  timestamp: FIXED_TIMESTAMP
)

puts
puts "Done. #{Dir.children(OUTPUT_DIR).count { |f| f.end_with?('.json') }} fixtures written."
