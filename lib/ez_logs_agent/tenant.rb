# frozen_string_literal: true

module EzLogsAgent
  # Schema-per-tenant and sharded apps: "Order #5" of tenant acme and of tenant beta are two records,
  # so their id carries the tenant ("acme:5"). Only from what the app itself declares, never guessed:
  # - a shard: the model's current shard, when it isn't the model's own default shard;
  # - a schema: Apartment's current tenant (its PostgreSQL schema adapter), when it isn't the adapter's
  #   default, for models that live in the tenant's schema (never Apartment's excluded models or a
  #   schema-qualified table, which are shared by every tenant).
  # An app that uses neither keeps its ids unchanged.
  module Tenant
    module_function

    # @return [String] the record's id, qualified by its tenant when it has one
    def qualified_id(record)
      tenant = of(record.class)
      tenant ? "#{tenant}:#{record.id}" : record.id.to_s
    end

    def of(klass)
      shard(klass) || schema(klass)
    rescue StandardError
      nil
    end

    def shard(klass)
      return nil unless klass.respond_to?(:current_shard) && klass.respond_to?(:default_shard)

      current = klass.current_shard
      current && current.to_s != klass.default_shard.to_s ? current.to_s[0, 63] : nil
    end

    # Apartment's schema adapter only (PostgreSQL schemas): its current tenant is an instance variable,
    # compared with the adapter's own default. A database-per-tenant adapter (MySQL, PostgreSQL without
    # schemas) would cost a query per row to read its tenant: its ids are left unqualified.
    def schema(klass)
      return nil unless defined?(::Apartment::Tenant) && defined?(::Apartment::Adapters::PostgresqlSchemaAdapter)
      return nil if klass.respond_to?(:table_name) && klass.table_name.to_s.include?(".")
      return nil if ::Apartment.respond_to?(:excluded_models) &&
                    Array(::Apartment.excluded_models).map(&:to_s).include?(klass.name.to_s)

      adapter = ::Apartment::Tenant.adapter
      return nil unless adapter.is_a?(::Apartment::Adapters::PostgresqlSchemaAdapter)

      current = adapter.current.to_s
      default = adapter.respond_to?(:default_tenant) ? adapter.default_tenant.to_s : "public"
      current.empty? || current == default || current == "public" ? nil : current[0, 63]
    end
  end
end
