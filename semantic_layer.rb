# semantic_layer.rb
#
# Entry point of the library. A consumer (a dashboard, an internal API or
# the AI adapter) only needs this:
#
#   layer  = SemanticLayer::Layer.load(definitions_path: "definitions",
#                                      connection: ActiveRecord::Base.connection)
#   tenant = SemanticLayer::Tenancy::TenantContext.new(company_id: current_company_id)
#   result = layer.run(query_json, tenant: tenant)
#
# It never sees SQL, never names a table, and cannot omit the tenant.

require_relative "errors"
require_relative "catalog/loader"
require_relative "engine/query"
require_relative "engine/query_validator"
require_relative "engine/planner"
require_relative "engine/sql_compiler"
require_relative "engine/executor"
require_relative "tenancy/tenant_context"

module SemanticLayer
  class Layer
    # Exposed for introspection: this is what feeds a dashboard's menu and
    # the AI agent's tool schema.
    attr_reader :catalog

    def self.load(definitions_path:, connection:)
      new(catalog: Catalog::Loader.load_from(definitions_path), connection: connection)
    end

    def initialize(catalog:, connection:)
      @catalog   = catalog
      @validator = Engine::QueryValidator.new(catalog)
      @planner   = Engine::Planner.new(catalog)
      @executor  = Engine::Executor.new(connection)
    end

    def run(query_input, tenant:)
      query = Engine::Query.parse(query_input)
      @validator.validate!(query)

      plan = @planner.plan(query, tenant: tenant)

      # A fresh compiler per query: it accumulates the binds in order.
      compiled = Engine::SqlCompiler.new(@catalog).compile(plan)

      @executor.run(compiled, plan)
    end
  end
end
