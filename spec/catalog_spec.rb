# spec/catalog_spec.rb
require "tmpdir"
require_relative "spec_helper"

# The catalog is validated once, at boot. These examples load a definitions
# directory built on the fly and assert that an incoherent catalog cannot
# exist: the process refuses to start instead of failing later, mid query.
RSpec.describe "Catalog validation at boot" do
  def load_definitions(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "module.yml"), yaml)
      SemanticLayer::Catalog::Loader.load_from(dir)
    end
  end

  # The strongest isolation guarantee in the design: an entity that does not
  # say which column carries the company cannot be part of the catalog, so no
  # code path can ever produce SQL without the tenant predicate.
  it "refuses an entity that does not declare its tenant column" do
    expect {
      load_definitions(<<~YAML)
        module: test
        entities:
          things:
            table: things
            dimensions:
              thing_name:
                column: name
      YAML
    }.to raise_error(SemanticLayer::ValidationError, /tenant_key/)
  end

  it "refuses two entities registering the same semantic name" do
    expect {
      load_definitions(<<~YAML)
        module: test
        entities:
          alpha:
            table: alpha
            tenant_key: company_id
            dimensions:
              shared_name:
                column: name
          beta:
            table: beta
            tenant_key: company_id
            dimensions:
              shared_name:
                column: name
      YAML
    }.to raise_error(SemanticLayer::ValidationError, /shared_name/)
  end

  it "refuses a derived formula that references a metric that does not exist" do
    expect {
      load_definitions(<<~YAML)
        module: test
        entities:
          things:
            table: things
            tenant_key: company_id
            metrics:
              total_things:
                type: count
              bad_rate:
                type: derived
                formula: "total_things / nonexistent_metric * 100"
      YAML
    }.to raise_error(SemanticLayer::ValidationError, /nonexistent_metric/)
  end

  it "loads the real definitions directory without errors" do
    expect(layer.catalog.metrics.keys).to include("completion_rate", "attendance_rate")
    expect(layer.catalog.dimensions.keys).to include("department", "attendance_date")
  end
end
