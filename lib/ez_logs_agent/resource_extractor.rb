# frozen_string_literal: true

module EzLogsAgent
  # ResourceExtractor provides explicit, opt-in helpers for extracting resource_ids from objects.
  #
  # This module is a small, boring utility that:
  # - Converts ActiveRecord model instances to resource_id hashes
  # - Extracts resource_ids from arrays of models
  # - Passes through existing resource_ids from hashes
  # - Returns empty array for unsupported inputs (defensive)
  #
  # ResourceExtractor does NOT:
  # - Automatically hook into anything
  # - Infer resources from SQL or context
  # - Guess actor or ownership
  # - Read RequestStore or global state
  # - Modify EventBuilder or other components
  # - Raise exceptions for unsupported input
  #
  # Missing resource_ids is acceptable.
  # Wrong or guessed resource_ids is NOT acceptable.
  #
  # @example Extract from ActiveRecord model
  #   user = User.find(123)
  #   EzLogsAgent::ResourceExtractor.from_record(user)
  #   # => [{ resource_type: "user_id", resource_id: "123" }]
  #
  # @example Extract from array of models
  #   orders = [Order.find(1), Order.find(2)]
  #   EzLogsAgent::ResourceExtractor.from_records(orders)
  #   # => [
  #   #   { resource_type: "order_id", resource_id: "1" },
  #   #   { resource_type: "order_id", resource_id: "2" }
  #   # ]
  #
  # @example Extract from hash
  #   hash = { resource_ids: [{ resource_type: "product_id", resource_id: "456" }] }
  #   EzLogsAgent::ResourceExtractor.from_hash(hash)
  #   # => [{ resource_type: "product_id", resource_id: "456" }]
  #
  # @example Unsupported input returns empty array
  #   EzLogsAgent::ResourceExtractor.from_record("not a model")
  #   # => []
  #
  module ResourceExtractor
    # Extracts resource_id from a single ActiveRecord model instance
    #
    # @param record [Object] Potentially an ActiveRecord model instance
    # @return [Array<Hash>] Array containing single resource_id hash, or empty array
    #
    # @example Valid ActiveRecord model
    #   user = User.find(123)
    #   ResourceExtractor.from_record(user)
    #   # => [{ resource_type: "user_id", resource_id: "123" }]
    #
    # @example Unsupported input
    #   ResourceExtractor.from_record("not a model")
    #   # => []
    #
    # @example Nil input
    #   ResourceExtractor.from_record(nil)
    #   # => []
    #
    def self.from_record(record)
      return [] if record.nil?
      return [] unless active_record_model?(record)

      [{
        resource_type: resource_type_from_class(record.class),
        resource_id: record.id.to_s
      }]
    rescue => e
      # Defensive: never raise exceptions, return empty array
      []
    end

    # Extracts resource_ids from an array of ActiveRecord model instances
    #
    # @param records [Array] Array of potentially ActiveRecord model instances
    # @return [Array<Hash>] Array of resource_id hashes, or empty array
    #
    # @example Valid ActiveRecord models
    #   orders = [Order.find(1), Order.find(2)]
    #   ResourceExtractor.from_records(orders)
    #   # => [
    #   #   { resource_type: "order_id", resource_id: "1" },
    #   #   { resource_type: "order_id", resource_id: "2" }
    #   # ]
    #
    # @example Mixed array (filters invalid entries)
    #   ResourceExtractor.from_records([user, "not a model", nil])
    #   # => [{ resource_type: "user_id", resource_id: "123" }]
    #
    # @example Empty array
    #   ResourceExtractor.from_records([])
    #   # => []
    #
    def self.from_records(records)
      return [] unless records.is_a?(Array)

      records.flat_map { |record| from_record(record) }.compact
    rescue => e
      # Defensive: never raise exceptions, return empty array
      []
    end

    # Extracts resource_ids from a hash containing a :resource_ids key
    #
    # @param hash [Hash] Hash potentially containing :resource_ids key
    # @return [Array<Hash>] Array of resource_id hashes, or empty array
    #
    # @example Valid hash with resource_ids
    #   hash = { resource_ids: [{ resource_type: "product_id", resource_id: "456" }] }
    #   ResourceExtractor.from_hash(hash)
    #   # => [{ resource_type: "product_id", resource_id: "456" }]
    #
    # @example Hash without resource_ids key
    #   ResourceExtractor.from_hash({ foo: "bar" })
    #   # => []
    #
    # @example Non-hash input
    #   ResourceExtractor.from_hash("not a hash")
    #   # => []
    #
    def self.from_hash(hash)
      return [] unless hash.is_a?(Hash)
      return [] unless hash.key?(:resource_ids)

      resource_ids = hash[:resource_ids]
      return [] unless resource_ids.is_a?(Array)

      resource_ids
    rescue => e
      # Defensive: never raise exceptions, return empty array
      []
    end

    # Checks if an object is an ActiveRecord model instance
    #
    # @param object [Object] Object to check
    # @return [Boolean] True if object is an ActiveRecord::Base instance
    # @private
    def self.active_record_model?(object)
      defined?(ActiveRecord::Base) && object.is_a?(ActiveRecord::Base)
    end
    private_class_method :active_record_model?

    # Converts a class to a resource_type string
    #
    # @param klass [Class] ActiveRecord model class
    # @return [String] Snake-cased class name with "_id" suffix
    #
    # @example
    #   resource_type_from_class(User) # => "user_id"
    #   resource_type_from_class(OrderItem) # => "order_item_id"
    #
    # @private
    def self.resource_type_from_class(klass)
      # Convert class name to snake_case and append "_id"
      class_name = klass.name
      snake_case = class_name
        .gsub(/::/, "/")
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("-", "_")
        .downcase

      "#{snake_case}_id"
    end
    private_class_method :resource_type_from_class
  end
end
