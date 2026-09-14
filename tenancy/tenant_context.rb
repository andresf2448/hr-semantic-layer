# tenancy/tenant_context.rb
require_relative "../errors"

module SemanticLayer
  module Tenancy
    # Represents "the company of the authenticated user".
    #
    # It has no default and does not accept nil: no tenant, no query.
    # Isolation is not a filter someone remembers to add, it is a
    # precondition for the object to exist at all.
    #
    # In a real Rails app this would be built in a before_action from
    # Current.user.company_id -- never from a request parameter.
    class TenantContext
      attr_reader :company_id

      # Fields the consumer may NOT mention in a query. The layer injects
      # the tenant; if the JSON carries it, that is an error rather than
      # something silently ignored.
      RESERVED_FIELDS = %w[
        company_id company companies tenant tenant_id
      ].freeze

      def self.reserved_field?(name)
        RESERVED_FIELDS.include?(name.to_s.strip.downcase)
      end

      def initialize(company_id:)
        @company_id = coerce(company_id)
        freeze
      end

      def to_h
        { company_id: company_id }
      end

      private

      def coerce(value)
        if value.nil?
          raise TenantError,
                "TenantContext requires a company_id: got nil. " \
                "No query can run without a company context."
        end

        integer =
          begin
            Integer(value)
          rescue ArgumentError, TypeError
            raise TenantError, "company_id must be an integer: got #{value.inspect}"
          end

        unless integer.positive?
          raise TenantError, "company_id must be a positive integer: got #{integer}"
        end

        integer
      end
    end
  end
end
