# engine/planner.rb
require_relative "../errors"
require_relative "derived_metrics"
require_relative "join_resolver"

module SemanticLayer
  module Engine
    # Takes an already validated Query and builds the PLAN: everything the
    # compiler needs in order to write the SQL, with no decisions left.
    #
    # This is where the three things the consumer did NOT say get resolved:
    #   - which base metrics are needed (expanding derived ones)
    #   - which tables have to be traversed (the JOIN path)
    #   - which company the data belongs to (the tenant)
    class Planner
      PlannedDimension = Struct.new(:definition, :granularity, keyword_init: true)
      PlannedFilter    = Struct.new(:definition, :operator, :values, keyword_init: true)

      Plan = Struct.new(
        :base_entity, :base_metrics, :outputs, :dimensions,
        :filters, :joins, :order_by, :limit, :tenant,
        keyword_init: true
      )

      def initialize(catalog)
        @catalog  = catalog
        @derived  = DerivedMetrics.new(catalog)
        @resolver = JoinResolver.new(catalog)
      end

      def plan(query, tenant:)
        resolution  = @derived.resolve(query.metrics)
        base_entity = base_entity_for(resolution.base_metrics)

        dimensions = query.dimensions.map do |ref|
          PlannedDimension.new(
            definition:  @catalog.dimension!(ref.name),
            granularity: ref.granularity
          )
        end

        filters = query.filters.map do |ref|
          PlannedFilter.new(
            definition: @catalog.dimension!(ref.dimension),
            operator:   ref.operator,
            values:     ref.values
          )
        end

        # A filter on a dimension of another entity needs its JOIN too, even
        # if that dimension is not requested as a grouping.
        targets = (dimensions + filters).map { |d| d.definition.entity_name }

        Plan.new(
          base_entity:  base_entity,
          base_metrics: resolution.base_metrics,
          outputs:      resolution.outputs,
          dimensions:   dimensions,
          filters:      filters,
          joins:        @resolver.resolve(base: base_entity, targets: targets),
          order_by:     query.order_by,
          limit:        query.limit,
          tenant:       tenant
        )
      end

      private

      # Every metric must come from the same fact table. Combining two fact
      # tables in a single query requires aggregating each one separately
      # (multi-CTE) in order to avoid fan-out.
      def base_entity_for(base_metrics)
        entities = base_metrics.map(&:entity_name).uniq
        return entities.first if entities.size == 1

        raise InvalidQueryError,
              "the query mixes metrics from more than one entity " \
              "(#{entities.join(', ')}). Combining them in a single query " \
              "requires aggregating each one separately (multi-CTE pattern) " \
              "to avoid row duplication through fan-out."
      end
    end
  end
end
