# catalog/validator.rb
require_relative "definitions"

module SemanticLayer
  module Catalog
    # Checks that the loaded catalog is coherent. It collects ALL errors and
    # reports them together -- it does not stop at the first one, so whoever
    # wrote the YAML can fix everything in a single pass.
    class Validator
      AGGREGATIONS  = %w[count sum avg min max].freeze
      GRANULARITIES = %w[day week month quarter year].freeze
      IDENTIFIER    = /[a-zA-Z_][a-zA-Z0-9_]*/.freeze

      def initialize(registry)
        @registry = registry
        @errors   = []
      end

      def validate!
        validate_entities
        validate_entity_aliases
        validate_relationships
        validate_unique_names
        validate_metrics
        validate_dimensions
        validate_derived_metrics

        if @errors.any?
          raise ValidationError,
                "Invalid catalog:\n  - #{@errors.uniq.join("\n  - ")}"
        end

        @registry
      end

      private

      def entities
        @registry.entities.values
      end

      # The SQL alias is the short part of the entity name, so two entities
      # from different modules sharing it would produce ambiguous SQL.
      def validate_entity_aliases
        entities.map { |e| [e.name.split(".").last, e.name] }
                .group_by(&:first)
                .each do |short, group|
          next if group.size == 1

          @errors << "entities #{group.map(&:last).join(', ')} share the alias " \
                     "'#{short}' in the generated SQL: rename one of them"
        end
      end

      def validate_entities
        entities.each do |e|
          @errors << "entity '#{e.name}' does not declare 'table'" if blank?(e.table)

          # CRITICAL: without tenant_key there is no way to isolate by company.
          # An entity missing this declaration CANNOT exist in the catalog.
          if blank?(e.tenant_key)
            @errors << "entity '#{e.name}' does not declare 'tenant_key' " \
                       "(required: without it multi-tenant isolation cannot be guaranteed)"
          end
        end
      end

      def validate_relationships
        entities.each do |e|
          e.relationships.each do |rel|
            unless @registry.entity(rel.to_entity)
              @errors << "relationship '#{rel.name}' of '#{e.name}' points to " \
                         "'#{rel.to_entity}', which does not exist in the catalog"
            end

            if blank?(rel.foreign_key)
              @errors << "relationship '#{rel.name}' of '#{e.name}' does not declare 'foreign_key'"
            end
          end
        end
      end

      # Semantic names live in a flat, global namespace: two modules cannot
      # register the same name.
      def validate_unique_names
        all_names = entities.flat_map { |e| e.metrics.keys + e.dimensions.keys }

        all_names.tally.select { |_, count| count > 1 }.each_key do |name|
          owners = entities.select { |e| e.metrics.key?(name) || e.dimensions.key?(name) }
                           .map(&:name)
          @errors << "name '#{name}' is declared in more than one entity " \
                     "(#{owners.join(', ')}): semantic names must be unique"
        end
      end

      def validate_metrics
        entities.each do |e|
          e.metrics.each_value do |m|
            next if m.derived? # derived metrics are validated separately

            unless AGGREGATIONS.include?(m.type)
              @errors << "metric '#{m.name}' uses type '#{m.type}', which is not " \
                         "valid (#{AGGREGATIONS.join(', ')} or derived)"
            end

            if m.type != "count" && blank?(m.column)
              @errors << "metric '#{m.name}' is of type '#{m.type}' and must declare 'column'"
            end

            m.filters.each do |fname|
              unless e.filters.key?(fname)
                @errors << "metric '#{m.name}' uses filter '#{fname}', which is not " \
                           "declared in entity '#{e.name}'"
              end
            end
          end
        end
      end

      def validate_dimensions
        entities.each do |e|
          e.dimensions.each_value do |d|
            @errors << "dimension '#{d.name}' does not declare 'column'" if blank?(d.column)

            next unless d.time?

            if d.granularities.empty?
              @errors << "time dimension '#{d.name}' does not declare 'granularities'"
            end

            invalid = d.granularities - GRANULARITIES
            if invalid.any?
              @errors << "dimension '#{d.name}' declares invalid granularities " \
                         "(#{invalid.join(', ')}); allowed: #{GRANULARITIES.join(', ')}"
            end
          end
        end
      end

      def validate_derived_metrics
        derived = @registry.metrics.values.select(&:derived?)

        derived.each do |m|
          if blank?(m.formula)
            @errors << "derived metric '#{m.name}' does not declare 'formula'"
            next
          end

          references_in(m.formula).each do |ref|
            unless @registry.metric(ref)
              @errors << "the formula of '#{m.name}' references '#{ref}', " \
                         "which is not a metric in the catalog"
            end
          end
        end

        derived.each { |m| detect_cycle(m.name, []) }
      end

      # Depth-first walk: if a name reappears along the path we are currently
      # walking, there is a cycle (a depends on b, and b on a).
      def detect_cycle(name, path)
        if path.include?(name)
          @errors << "dependency cycle between derived metrics: " \
                     "#{(path + [name]).join(' -> ')}"
          return
        end

        metric = @registry.metric(name)
        return unless metric&.derived?

        references_in(metric.formula).each { |ref| detect_cycle(ref, path + [name]) }
      end

      def references_in(formula)
        formula.to_s.scan(IDENTIFIER).uniq
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
