# engine/query_validator.rb
require_relative "../errors"
require_relative "../tenancy/tenant_context"

module SemanticLayer
  module Engine
    # Checks that a Query -- already normalized in SHAPE -- makes sense
    # against the CATALOG: that everything it asks for exists, that the
    # granularities are supported, and that it does not touch the tenant.
    #
    # Unlike the catalog validator (which collects every error because it
    # runs once at boot), this one fails on the first: it runs on every
    # query, and one error is enough to reject it.
    class QueryValidator
      def initialize(catalog)
        @catalog = catalog
      end

      def validate!(query)
        validate_metrics!(query)
        validate_dimensions!(query)
        validate_filters!(query)
        validate_order_by!(query)
        query
      end

      private

      def validate_metrics!(query)
        if query.metrics.empty?
          raise InvalidQueryError, "the query must request at least one metric"
        end

        # metric! raises UnknownMetricError listing the available names.
        query.metrics.each { |name| @catalog.metric!(name) }
      end

      def validate_dimensions!(query)
        query.dimensions.each do |ref|
          reject_reserved!(ref.name, "dimension")

          dimension = @catalog.dimension!(ref.name)
          next if ref.granularity.nil?

          unless dimension.time?
            raise InvalidQueryError,
                  "'#{ref.name}' is not a time dimension: it does not accept 'granularity'"
          end

          unless dimension.supports_granularity?(ref.granularity)
            raise InvalidQueryError,
                  "dimension '#{ref.name}' does not support granularity " \
                  "'#{ref.granularity}'. Supported: #{dimension.granularities.join(', ')}"
          end
        end
      end

      def validate_filters!(query)
        query.filters.each do |filter|
          reject_reserved!(filter.dimension, "filter")
          @catalog.dimension!(filter.dimension)
        end
      end

      # You can only order by something the query actually returns: the final
      # SELECT exposes nothing but the requested metrics and dimensions.
      def validate_order_by!(query)
        selectable = query.metrics + query.dimension_names

        query.order_by.each do |order|
          next if selectable.include?(order.field)

          raise InvalidQueryError,
                "cannot order by '#{order.field}': it is not among the requested " \
                "metrics or dimensions (#{selectable.join(', ')})"
        end
      end

      # The tenant is injected by the layer. If the consumer mentions it that
      # is an explicit error -- silently ignoring it would mask either a bug
      # or an attempt to reach another company's data.
      def reject_reserved!(name, context)
        return unless Tenancy::TenantContext.reserved_field?(name)

        raise InvalidQueryError,
              "'#{name}' cannot be used as a #{context}: per-company isolation " \
              "is applied automatically by the semantic layer"
      end
    end
  end
end
