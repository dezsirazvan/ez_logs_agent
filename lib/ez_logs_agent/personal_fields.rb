# frozen_string_literal: true

require "ipaddr"
require "set"

module EzLogsAgent
  # Personal fields: phone numbers, postal addresses, precise locations, birth dates, IP addresses and
  # identity-document numbers. Their values never leave the app; a change to one still does ("changed
  # the phone"). The same rule runs on the EZLogs server, in ezlogs-nextjs and in both SQL installs
  # (spec/fixtures/personal_key_vectors.json is shared byte for byte).
  #
  # A key is personal by its words. A model or table that is itself a list of phones, addresses or IPs
  # ("PhoneNumber", "user_addresses") makes its value columns personal too: its "number" is the phone.
  #
  # A value is masked unless it is nil, blank or a boolean (`phone_verified: true` says nothing about
  # the number). Only changed values are ever sent for an update, so two masked sides mean it changed.
  module PersonalFields
    MASK = "[FILTERED]"

    WORDS = %w[phone phones phonenumber telephone cellphone msisdn fax address addresses addr street postcode
               postal zipcode birth birthday birthdate born dob passport ip ips ipv4 ipv6 latitude longitude lat lng
               geolocation].to_set.freeze
    NUMBERED = /\A(?:phone|address|addr|line)\d+\z/ # phone1, address2, line1
    # Documents whose number ends in "id" or "number" (checked before the "id" exclusion), and pairs of
    # words that only together name a personal value.
    PHRASES = /
      (?:\A|_)(?:
        (?:tax|vat|national|passport|id_card|id|document|personal|fiscal)_(?:id|number|no|code)
      | drivers?_licen[cs]e | national_insurance | social_insurance | fiscal_code | tax_code
      | (?:tel|cell|mobile)_(?:number|no|phone) | cell_phone | house_number | remote_addr | forwarded_for | post_code
      )(?:_|\z)
    /x.freeze
    DOCUMENT_ID = /(?:\A|_)(?:tax|vat|national|passport|id_card)_(?:id|number|no)\z/.freeze
    # A link to a record, a kind, a count, a time or a state: never the value itself.
    NOT_A_VALUE = %w[id ids uuid type kind count at status state verified confirmed].to_set.freeze
    # An email names the person (actors are named by it).
    EMAIL_WORDS = %w[email mail].freeze
    PHONE_ALONGSIDE_EMAIL = %w[phone phones mobile telephone].freeze
    # A table that is a list of these: its value columns are personal.
    PERSONAL_TABLE_LAST = %w[phone phones telephone telephones address addresses ip ips].to_set.freeze
    NUMBER_WORDS = %w[number numbers].freeze
    PHONE_WORDS = %w[phone telephone mobile].freeze

    module_function

    # Lower-cased words of a key: "addressLine1" → address, line1; "IPAddress" → ip, address.
    def words(key)
      key.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z0-9])([A-Z])/, '\1_\2')
         .downcase.split(/[^a-z0-9]+/).reject(&:empty?)
    end

    def personal_key?(key)
      w = words(key)
      return false if w.empty?

      joined = w.join("_")
      phrase = joined.match?(PHRASES)
      word = w.any? { |x| WORDS.include?(x) || x.match?(NUMBERED) }
      return false if w.intersect?(EMAIL_WORDS) && !w.intersect?(PHONE_ALONGSIDE_EMAIL)
      return true if phrase && !NOT_A_VALUE.include?(w.last)
      return true if joined.match?(DOCUMENT_ID)
      return false if NOT_A_VALUE.include?(w.last)

      word || phrase || w == ["tel"] || w == ["mobile"] || w == ["cell"] ||
        (w.include?("zip") && (w.size == 1 || w.include?("code")))
    end

    # A model or table that is a list of phones, addresses or IPs ("user_addresses", "PhoneNumber",
    # "Customer::Address"), not one that only mentions one ("phone_calls", "address_books").
    def personal_table?(table)
      w = words(table)
      return false if w.empty?

      PERSONAL_TABLE_LAST.include?(w.last) || (NUMBER_WORDS.include?(w.last) && w.size > 1 && PHONE_WORDS.include?(w[-2]))
    end

    # A column of a row: personal by its own name, or a value column of a personal table (never its
    # key, a link, a kind, a count, a time or a state).
    def personal_column?(key, table = nil)
      return true if personal_key?(key)
      return false unless table && personal_table?(table)

      w = words(key)
      w.any? && !NOT_A_VALUE.include?(w.last) && !w.intersect?(EMAIL_WORDS)
    end

    # Nil, blank and booleans say nothing about the person: "removed the phone" stays readable.
    def mask_value(value)
      return value if value.nil? || value == true || value == false
      return value if value.is_a?(String) && value.strip.empty?

      MASK
    end

    # A value with every personal key inside it masked, at any depth.
    def mask_nested(value)
      case value
      when Hash then value.to_h { |k, v| [k, personal_key?(k) ? mask_value(v) : mask_nested(v)] }
      when Array then value.map { |v| mask_nested(v) }
      else value
      end
    end

    # A phone number written with its country code or an IP address inside text: what a job hands an
    # SMS or a lookup service by position, where no name says what it is. Validated (digit count,
    # IPAddr), so versions, amounts and ids stay.
    INTL_PHONE = %r{(?<![\w+])(?:\+\d{1,3}|00[1-9]\d{0,2}[ .\-])(?:[ .\-]?\(?\d{1,7}\)?){2,6}(?![\w\-/]|[.,]\d)}.freeze
    IPV4 = /(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])/.freeze
    IPV6 = /(?<![\w:])(?=[0-9A-Fa-f:]*:[0-9A-Fa-f:]*:)[0-9A-Fa-f:]{2,39}(?![\w:])/.freeze
    MAX_SCANNED = 65_536

    def mask_text(value)
      return value unless value.is_a?(String) && value.length <= MAX_SCANNED && value.match?(/\d/)

      value.gsub(INTL_PHONE) { |m| m.count("0-9").between?(8, 15) ? MASK : m }
           .gsub(IPV4) { |m| ip?(m) ? MASK : m }
           .gsub(IPV6) { |m| ip?(m) ? MASK : m }
    end

    def ip?(text)
      IPAddr.new(text)
      true
    rescue IPAddr::Error, ArgumentError
      false
    end

    # Every string inside a value, phones and IPs masked (mask_text).
    def mask_text_deep(value)
      case value
      when Hash then value.transform_values { |v| mask_text_deep(v) }
      when Array then value.map { |v| mask_text_deep(v) }
      else mask_text(value)
      end
    end
  end
end
