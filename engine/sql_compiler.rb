# engine/sql_compiler.rb
require_relative "../errors"
require_relative "derived_metrics"
require_relative "join_resolver"

module SemanticLayer
  module Engine
    # Turns a Plan into SQL + parameters.
    #
    # SECURITY RULE, in one line:
    #   identifiers and keywords -> from the catalog allow-list
    #   user values              -> always as binds ($1, $2, ...)
    #
    # A value coming from the consumer is never interpolated. Table, column
    # and granularity names ARE interpolated, but they can only come from
    # already validated YAML definitions: the consumer has no way to inject
    # a new one.
    #
    # One instance per query (it accumulates the binds in order).
    class SqlCompiler
      Compiled = Struct.new(:sql, :binds, keyword_init: true)

      METRIC_PREFIX = "m_"

      OPERATORS = {
        "eq"  => "=",
        "ne"  => "<>",
        "gt"  => ">",
        "gte" => ">=",
        "lt"  => "<",
        "lte" => "<="
      }.freeze

      def initialize(catalog)
        @catalog = catalog
        @derived = DerivedMetrics.new(catalog)
        @binds   = []
      end

      def compile(plan)
        @binds = []

        # Order matters: binds are numbered by the order in which they
        # appear in the SQL text, and the inner query comes before the outer.
        inner = inner_query(plan)
        outer = outer_query(plan)

        Compiled.new(sql: "#{inner}\n#{outer}", binds: @binds)
      end

      private

      # Inner level: aggregates. Here and only here are real rows touched.
      def inner_query(plan)
        base       = @catalog.entity!(plan.base_entity)
        base_alias = JoinResolver.alias_for(plan.base_entity)

        selects  = plan.dimensions.map { |d| "#{dimension_expression(d)} AS #{d.definition.name}" }
        selects += plan.base_metrics.map { |m| "#{metric_expression(m)} AS #{METRIC_PREFIX}#{m.name}" }

        lines = []
        lines << "WITH base AS ("
        lines << "  SELECT"
        lines << selects.map { |s| "    #{s}" }.join(",\n")
        lines << "  FROM #{base.table} #{base_alias}"
        plan.joins.each { |join| lines << "  #{join_clause(join)}" }
        lines << "  WHERE #{where_conditions(plan).join("\n    AND ")}"
        lines << "  GROUP BY #{(1..plan.dimensions.size).to_a.join(', ')}" unless plan.dimensions.empty?
        lines << ")"
        lines.join("\n")
      end

      # Outer level: projects. It only sees ALREADY aggregated columns, so a
      # derived formula CANNOT be computed row by row.
      def outer_query(plan)
        selects = plan.dimensions.map { |d| d.definition.name }

        selects += plan.outputs.map do |output|
          if output.ast.nil?
            "#{METRIC_PREFIX}#{output.name} AS #{output.name}"
          else
            expression = @derived.to_sql(output.ast) { |name| "#{METRIC_PREFIX}#{name}" }
            "#{expression} AS #{output.name}"
          end
        end

        lines = []
        lines << "SELECT"
        lines << selects.map { |s| "  #{s}" }.join(",\n")
        lines << "FROM base"

        unless plan.order_by.empty?
          clauses = plan.order_by.map { |o| "#{o.field} #{o.direction.upcase}" }
          lines << "ORDER BY #{clauses.join(', ')}"
        end

        lines << "LIMIT #{bind(plan.limit)}"
        lines.join("\n")
      end

      def dimension_expression(planned)
        definition = planned.definition
        column     = "#{JoinResolver.alias_for(definition.entity_name)}.#{definition.column}"

        return column if planned.granularity.nil?

        # The granularity was already validated against the list declared in
        # the YAML: it is an identifier from an allow-list, not a user value.
        #
        # ::date because DATE_TRUNC returns a timestamp: a quarter is a date
        # bucket, not an instant, so the consumer gets "2025-01-01" rather
        # than "2025-01-01 00:00:00 +0000".
        "DATE_TRUNC('#{planned.granularity}', #{column})::date"
      end

      def metric_expression(metric)
        table_alias = JoinResolver.alias_for(metric.entity_name)

        aggregation =
          if metric.type == "count"
            metric.column ? "COUNT(#{table_alias}.#{metric.column})" : "COUNT(*)"
          else
            "#{metric.type.upcase}(#{table_alias}.#{metric.column})"
          end

        return aggregation if metric.filters.empty?

        # FILTER (WHERE ...) instead of pushing the condition into the global
        # WHERE: this lets two metrics with different filters coexist in the
        # same query.
        entity     = @catalog.entity!(metric.entity_name)
        conditions = metric.filters.map do |name|
          entity.filters.fetch(name).expression.gsub("{{table}}", table_alias)
        end

        "#{aggregation} FILTER (WHERE #{conditions.join(' AND ')})"
      end

      def join_clause(join)
        from_entity = @catalog.entity!(join.from_entity)
        to_entity   = @catalog.entity!(join.to_entity)
        from_alias  = JoinResolver.alias_for(join.from_entity)
        to_alias    = JoinResolver.alias_for(join.to_entity)

        # The second condition (tenant = tenant) is defense in depth: not
        # even when joining tables can you cross into another company.
        "INNER JOIN #{to_entity.table} #{to_alias}" \
        " ON #{to_alias}.#{join.references} = #{from_alias}.#{join.foreign_key}" \
        " AND #{to_alias}.#{to_entity.tenant_key} = #{from_alias}.#{from_entity.tenant_key}"
      end

      def where_conditions(plan)
        base       = @catalog.entity!(plan.base_entity)
        base_alias = JoinResolver.alias_for(plan.base_entity)

        # The tenant predicate ALWAYS comes first and is ALWAYS present.
        conditions = ["#{base_alias}.#{base.tenant_key} = #{bind(plan.tenant.company_id)}"]
        conditions + plan.filters.map { |filter| filter_condition(filter) }
      end

      def filter_condition(filter)
        definition = filter.definition
        column     = "#{JoinResolver.alias_for(definition.entity_name)}.#{definition.column}"

        case filter.operator
        when "between"
          "#{column} BETWEEN #{bind(filter.values[0])} AND #{bind(filter.values[1])}"
        when "in"
          "#{column} IN (#{filter.values.map { |v| bind(v) }.join(', ')})"
        else
          "#{column} #{OPERATORS.fetch(filter.operator)} #{bind(filter.values.first)}"
        end
      end

      def bind(value)
        @binds << value
        "$#{@binds.size}"
      end
    end
  end
end
