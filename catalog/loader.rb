# catalog/loader.rb
require "yaml"
require_relative "definitions"
require_relative "registry"
require_relative "validator"

module SemanticLayer
  module Catalog
    # Reads the YAML files under definitions/, turns them into Ruby objects
    # and returns an already validated Registry. If anything is wrong it
    # blows up HERE, at boot -- never halfway through a production query.
    class Loader
      DEFAULT_DIRECTORY = File.expand_path("../definitions", __dir__)

      def self.load_from(directory = DEFAULT_DIRECTORY)
        new(directory).load
      end

      def initialize(directory)
        @directory = directory
      end

      def load
        entities = {}

        files.each do |path|
          # safe_load: a definition file is DATA. It must never be able to
          # instantiate arbitrary Ruby objects when deserialized.
          doc = YAML.safe_load_file(path)

          module_name = doc["module"]
          if module_name.nil? || module_name.to_s.strip.empty?
            raise ValidationError, "#{File.basename(path)} does not declare 'module'"
          end

          (doc["entities"] || {}).each do |entity_key, spec|
            entity = build_entity(module_name, entity_key, spec)
            entities[entity.name] = entity
          end
        end

        raise ValidationError, "no definitions found in #{@directory}" if entities.empty?

        registry = Registry.new(entities)
        Validator.new(registry).validate!
        registry
      end

      private

      def files
        Dir.glob(File.join(@directory, "*.yml")).sort
      end

      def build_entity(module_name, entity_key, spec)
        full_name = "#{module_name}.#{entity_key}"

        Entity.new(
          name:          full_name,
          module_name:   module_name,
          table:         spec["table"],
          # Deliberately no default: if the YAML does not declare it, the
          # validator rejects the entity. Isolation is never assumed.
          tenant_key:    spec["tenant_key"],
          relationships: build_relationships(full_name, spec["relationships"]),
          dimensions:    build_dimensions(full_name, spec["dimensions"]),
          metrics:       build_metrics(full_name, spec["metrics"]),
          filters:       build_filters(spec["filters"])
        )
      end

      def build_filters(specs)
        (specs || {}).map { |name, fspec|
          [name, Filter.new(
            name:       name,
            expression: fspec["expression"]
          )]
        }.to_h
      end

      def build_dimensions(entity_name, specs)
        (specs || {}).map { |name, dspec|
          [name, Dimension.new(
            name:          name,
            entity_name:   entity_name,
            column:        dspec["column"],
            type:          dspec["type"] || "string",
            granularities: dspec["granularities"] || [],
            label:         dspec["label"] || name
          )]
        }.to_h
      end

      def build_metrics(entity_name, specs)
        (specs || {}).map { |name, mspec|
          [name, Metric.new(
            name:        name,
            entity_name: entity_name,
            type:        mspec["type"],
            column:      mspec["column"],
            filters:     mspec["filters"] || [],
            formula:     mspec["formula"],
            unit:        mspec["unit"],
            label:       mspec["label"] || name
          )]
        }.to_h
      end

      def build_relationships(entity_name, specs)
        (specs || []).map do |rspec|
          Relationship.new(
            name:        rspec["name"],
            type:        rspec["type"] || "many_to_one",
            from_entity: entity_name,
            to_entity:   rspec["entity"],
            foreign_key: rspec["foreign_key"],
            references:  rspec["references"] || "id"
          )
        end
      end
    end
  end
end