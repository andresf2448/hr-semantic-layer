# engine/join_resolver.rb
require_relative "../errors"

module SemanticLayer
  module Engine
    # Derives the JOIN path between entities from the relationships declared
    # in the catalog. The consumer never writes a JOIN.
    #
    # It ONLY walks many_to_one relationships. That is not a limitation, it
    # is a guarantee: walking the other way (one to many) is exactly what
    # multiplies rows and inflates metrics. This resolver CANNOT produce
    # fan-out, because it does not know how to walk in that direction.
    class JoinResolver
      Join = Struct.new(
        :from_entity, :to_entity, :foreign_key, :references,
        keyword_init: true
      )

      # The alias each entity gets in the SQL: the short part of its name
      # ("performance.reviews" -> "reviews"). The compiler uses it too.
      def self.alias_for(entity_name)
        entity_name.split(".").last
      end

      def initialize(catalog)
        @catalog = catalog
      end

      # base:    entity the requested metrics live in.
      # targets: entities the requested dimensions live in.
      # Returns the JOINs in order, without duplicates.
      def resolve(base:, targets:)
        joins = []
        seen  = []

        targets.uniq.each do |target|
          next if target == base

          path = shortest_path(base, target)

          if path.nil?
            raise InvalidQueryError,
                  "there is no way to relate '#{target}' to '#{base}': no path " \
                  "of declared relationships exists between them"
          end

          path.each do |join|
            key = [join.from_entity, join.to_entity]
            next if seen.include?(key)

            seen  << key
            joins << join
          end
        end

        joins
      end

      private

      # Breadth-first search: finds the SHORTEST path, which guarantees no
      # unnecessary tables are dragged into the JOIN.
      def shortest_path(from, to)
        queue   = [[from, []]]
        visited = [from]

        until queue.empty?
          current, path = queue.shift

          @catalog.entity!(current).relationships.each do |rel|
            next unless rel.type == "many_to_one"
            next if visited.include?(rel.to_entity)

            join = Join.new(
              from_entity: current,
              to_entity:   rel.to_entity,
              foreign_key: rel.foreign_key,
              references:  rel.references
            )

            return path + [join] if rel.to_entity == to

            visited << rel.to_entity
            queue   << [rel.to_entity, path + [join]]
          end
        end

        nil
      end
    end
  end
end
