# engine/executor.rb
require "pg"
require_relative "../errors"
require_relative "join_resolver"

module SemanticLayer
  module Engine
    # Runs the compiled SQL and assembles the response.
    #
    # Two responsibilities, both about security or trust:
    #   - Opens a transaction and declares the tenant at session level
    #     (set_config with local=true). That makes the layer compatible with
    #     RLS policies if the platform has them enabled, without the layer
    #     having to configure them (those tables do not belong to it).
    #   - Returns, alongside the data, full traceability: the generated SQL,
    #     the parameters, and the JOIN path that was used. Without that, a
    #     number produced by an AI agent is not verifiable.
    class Executor
      Result = Struct.new(:data, :meta, keyword_init: true)

      TENANT_SETTING = "app.current_company_id"

      def initialize(connection)
        @connection = connection
      end

      def run(compiled, plan)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        rows    = []

        @connection.transaction do
          raw = @connection.raw_connection

          # local: true -> the value lives only inside this transaction.
          # set_config (a function) is used instead of SET LOCAL because it
          # accepts parameters: not even the tenant is interpolated.
          raw.exec_params(
            "SELECT set_config($1, $2, true)",
            [TENANT_SETTING, plan.tenant.company_id.to_s]
          )

          result = raw.exec_params(compiled.sql, compiled.binds)
          result.type_map = type_map(raw)
          rows = result.to_a
        end

        elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)

        Result.new(data: rows, meta: meta_for(compiled, plan, rows, elapsed_ms))
      end

      private

      def meta_for(compiled, plan, rows, elapsed_ms)
        {
          sql:        compiled.sql,
          binds:      compiled.binds,
          metrics:    plan.outputs.map(&:name),
          dimensions: plan.dimensions.map { |d| d.definition.name },
          join_path:  join_path(plan),
          tenant:     plan.tenant.to_h,
          row_count:  rows.size,
          elapsed_ms: elapsed_ms
        }
      end

      # The entities the query traversed, in order.
      def join_path(plan)
        [plan.base_entity] + plan.joins.map(&:to_entity)
      end

      # Without a type map PG returns everything as strings. With it,
      # integers arrive as Integer, NUMERIC as BigDecimal and dates as Date.
      # Built once per executor.
      def type_map(raw_connection)
        @type_map ||= PG::BasicTypeMapForResults.new(raw_connection)
      end
    end
  end
end
