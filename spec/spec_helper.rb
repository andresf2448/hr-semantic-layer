# spec/spec_helper.rb
require "pg"
require_relative "../db/connection"
require_relative "../semantic_layer"

module SpecHelpers
  def connection
    ActiveRecord::Base.connection
  end

  def layer
    @layer ||= SemanticLayer::Layer.load(
      definitions_path: File.expand_path("../definitions", __dir__),
      connection: connection
    )
  end

  def tenant(company_id)
    SemanticLayer::Tenancy::TenantContext.new(company_id: company_id)
  end

  # Runs raw SQL with the same type mapping the executor uses, so results can
  # be compared like for like.
  def run_sql(sql, binds = [])
    raw    = connection.raw_connection
    result = raw.exec_params(sql, binds)
    result.type_map = PG::BasicTypeMapForResults.new(raw)
    result.to_a
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.include SpecHelpers

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
