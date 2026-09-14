# catalog/registry.rb
require_relative "definitions"

module SemanticLayer
  module Catalog
    # The loaded, validated catalog: the single source of truth about what
    # exists in the semantic layer. Immutable once loaded.
    class Registry
      attr_reader :entities

      def initialize(entities)
        @entities = entities.freeze
      end

      def entity(name)
        @entities[name]
      end

      def entity!(name)
        entity(name) || raise(UnknownEntityError, "entity '#{name}' does not exist")
      end

      # Flat, global namespace: semantic names are unique across the whole
      # catalog (the validator enforces it). The consumer asks for
      # "avg_performance_score", not "performance.reviews.avg_performance_score".
      def metrics
        @metrics ||= @entities.values
                              .flat_map { |e| e.metrics.values }
                              .to_h { |m| [m.name, m] }
      end

      def dimensions
        @dimensions ||= @entities.values
                                 .flat_map { |e| e.dimensions.values }
                                 .to_h { |d| [d.name, d] }
      end

      def metric(name)
        metrics[name.to_s]
      end

      def dimension(name)
        dimensions[name.to_s]
      end

      def metric!(name)
        metric(name) || raise(
          UnknownMetricError,
          "metric '#{name}' does not exist. Available: #{metrics.keys.sort.join(', ')}"
        )
      end

      def dimension!(name)
        dimension(name) || raise(
          UnknownDimensionError,
          "dimension '#{name}' does not exist. Available: #{dimensions.keys.sort.join(', ')}"
        )
      end

      # Introspection: what a dashboard, an internal API or an AI agent's
      # tool schema needs in order to know what can be asked for.
      def describe
        {
          metrics: metrics.values.map do |m|
            { name: m.name, label: m.label, type: m.type,
              unit: m.unit, derived: m.derived? }
          end,
          dimensions: dimensions.values.map do |d|
            { name: d.name, label: d.label, type: d.type,
              granularities: d.granularities }
          end
        }
      end
    end
  end
end