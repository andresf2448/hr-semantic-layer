# engine/query.rb
require_relative "../errors"
require_relative "../tenancy/tenant_context"

module SemanticLayer
  module Engine
    # The consumer's query, parsed but not yet validated against the catalog.
    # Its only job is to normalize the SHAPE of the JSON: it accepts both
    # "department" and { "name" => "review_period", "granularity" => "quarter" }
    # and leaves them in a single uniform structure.
    class Query
      DimensionRef = Struct.new(:name, :granularity, keyword_init: true)
      FilterRef    = Struct.new(:dimension, :operator, :values, keyword_init: true)
      OrderRef     = Struct.new(:field, :direction, keyword_init: true)

      OPERATORS     = %w[eq ne gt gte lt lte in between].freeze
      DIRECTIONS    = %w[asc desc].freeze
      MAX_LIMIT     = 10_000
      DEFAULT_LIMIT = 1_000

      attr_reader :metrics, :dimensions, :filters, :order_by, :limit

      def self.parse(input)
        raise InvalidQueryError, "the query must be a JSON object" unless input.is_a?(Hash)

        new(
          metrics:    Array(input["metrics"]    || input[:metrics]),
          dimensions: Array(input["dimensions"] || input[:dimensions]),
          filters:    Array(input["filters"]    || input[:filters]),
          order_by:   Array(input["order_by"]   || input[:order_by]),
          limit:      input["limit"] || input[:limit]
        )
      end

      def initialize(metrics:, dimensions: [], filters: [], order_by: [], limit: nil)
        @metrics    = metrics.map(&:to_s)
        @dimensions = dimensions.map { |d| parse_dimension(d) }
        @filters    = filters.map    { |f| parse_filter(f) }
        @order_by   = order_by.map   { |o| parse_order(o) }
        @limit      = parse_limit(limit)
      end

      def dimension_names
        @dimensions.map(&:name)
      end

      private

      # A dimension can arrive as a plain string or as an object carrying a
      # time granularity.
      def parse_dimension(raw)
        case raw
        when String, Symbol
          DimensionRef.new(name: raw.to_s, granularity: nil)
        when Hash
          name = raw["name"] || raw[:name]
          raise InvalidQueryError, "every dimension must declare 'name'" if blank?(name)

          DimensionRef.new(
            name:        name.to_s,
            granularity: (raw["granularity"] || raw[:granularity])&.to_s
          )
        else
          raise InvalidQueryError,
                "invalid dimension: #{raw.inspect} (expected a string or an object with 'name')"
        end
      end

      def parse_filter(raw)
        unless raw.is_a?(Hash)
          raise InvalidQueryError, "every filter must be an object, got: #{raw.inspect}"
        end

        dimension = raw["dimension"] || raw[:dimension]
        operator  = (raw["operator"] || raw[:operator] || "eq").to_s
        values    = raw.key?("values") ? raw["values"] : raw[:values]

        raise InvalidQueryError, "every filter must declare 'dimension'" if blank?(dimension)

        unless OPERATORS.include?(operator)
          raise InvalidQueryError,
                "operator '#{operator}' is not supported. Available: #{OPERATORS.join(', ')}"
        end

        values = Array(values)
        raise InvalidQueryError, "the filter on '#{dimension}' declares no 'values'" if values.empty?

        if operator == "between" && values.size != 2
          raise InvalidQueryError,
                "operator 'between' requires exactly 2 values, got #{values.size}"
        end

        FilterRef.new(dimension: dimension.to_s, operator: operator, values: values)
      end

      def parse_order(raw)
        case raw
        when String, Symbol
          OrderRef.new(field: raw.to_s, direction: "asc")
        when Hash
          field     = raw["field"] || raw[:field]
          direction = (raw["direction"] || raw[:direction] || "asc").to_s.downcase

          raise InvalidQueryError, "every 'order_by' entry must declare 'field'" if blank?(field)

          unless DIRECTIONS.include?(direction)
            raise InvalidQueryError,
                  "invalid direction '#{direction}'. Use 'asc' or 'desc'"
          end

          OrderRef.new(field: field.to_s, direction: direction)
        else
          raise InvalidQueryError, "invalid 'order_by' entry: #{raw.inspect}"
        end
      end

      # An always-present limit guards against a query trying to pull millions
      # of rows: with companies of up to 50,000 employees, an ungrouped query
      # could return far too much.
      def parse_limit(value)
        return DEFAULT_LIMIT if value.nil?

        limit =
          begin
            Integer(value)
          rescue ArgumentError, TypeError
            raise InvalidQueryError, "'limit' must be an integer, got #{value.inspect}"
          end

        raise InvalidQueryError, "'limit' must be positive" unless limit.positive?

        [limit, MAX_LIMIT].min
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
    end
  end
end
