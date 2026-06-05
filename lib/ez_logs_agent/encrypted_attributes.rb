# frozen_string_literal: true

module EzLogsAgent
  # Primary defense against capturing encrypted columns: read the host
  # app's `encrypts :foo` declarations (Rails 7+ ActiveRecord::Encryption)
  # and drop those attributes from anywhere we'd ship them on the wire.
  #
  # Two callers:
  # - DatabaseCapturer (per-record callbacks) — has a model INSTANCE,
  #   used to also work from `record.class`.
  # - BulkDatabaseCapturer (AS::Notifications path) — has only the model
  #   CLASS (the bulk SQL never instantiated a record). So this module
  #   takes a class, not an instance — both call sites converge.
  #
  # The Rails API is `ModelClass.encrypted_attributes` (Symbol array).
  # Available since Rails 7.0; older Rails or non-AR classes return false
  # from this module, which is the fail-open default for the encrypts
  # check. The pattern-based fallback in SensitivePatterns is the second
  # layer of defense for hosts that don't (or can't) declare encrypts.
  module EncryptedAttributes
    module_function

    # @param model_class [Class, nil] The AR class
    # @param attribute [String, Symbol, nil] The attribute name
    # @return [Boolean] true iff the host app declared `encrypts :<attribute>`
    #   on `model_class` (or an ancestor). False on any error, missing API,
    #   or empty list — see comment about fail-open semantics above.
    def attribute?(model_class, attribute)
      return false if model_class.nil? || attribute.nil?
      return false unless model_class.respond_to?(:encrypted_attributes)

      declared = model_class.encrypted_attributes
      return false if declared.nil? || declared.empty?

      attribute_str = attribute.to_s
      declared.any? { |declared_attr| declared_attr.to_s == attribute_str }
    rescue StandardError
      # Same rescue policy as the previous inline check in DatabaseCapturer:
      # if introspection raises (host app monkey-patched the API, weird
      # AR class hierarchy), fall through to the pattern-based fallback
      # rather than crash the capture path.
      false
    end
  end
end
