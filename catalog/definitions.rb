# catalog/definitions.rb
require_relative "../errors"

module SemanticLayer
  module Catalog
    # Value objects: the Ruby representation of what the YAML files declare.
    # NONE of them knows what SQL is. They only hold the declaration.

    Filter = Struct.new(:name, :expression, keyword_init: true)

    Dimension = Struct.new(
      :name, :entity_name, :column, :type, :granularities, :label,
      keyword_init: true
    ) do
      def time?
        type == "time"
      end

      def supports_granularity?(granularity)
        time? && granularities.include?(granularity.to_s)
      end
    end

    Metric = Struct.new(
      :name, :entity_name, :type, :column, :filters, :formula, :unit, :label,
      keyword_init: true
    ) do
      def derived?
        type == "derived"
      end
    end

    Relationship = Struct.new(
      :name, :type, :from_entity, :to_entity, :foreign_key, :references,
      keyword_init: true
    )

    Entity = Struct.new(
      :name, :module_name, :table, :tenant_key,
      :relationships, :dimensions, :metrics, :filters,
      keyword_init: true
    )
  end
end