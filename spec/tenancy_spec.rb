# spec/tenancy_spec.rb
require_relative "spec_helper"

RSpec.describe "Isolation between companies" do
  Tenancy = SemanticLayer::Tenancy

  describe "the tenant context cannot be omitted or faked" do
    it "cannot be built without a company_id" do
      expect { Tenancy::TenantContext.new(company_id: nil) }
        .to raise_error(SemanticLayer::TenantError, /nil/)
    end

    it "rejects a company_id that is not an integer" do
      expect { Tenancy::TenantContext.new(company_id: "'; DROP TABLE employees; --") }
        .to raise_error(SemanticLayer::TenantError, /integer/)
    end

    it "rejects a non positive company_id" do
      expect { Tenancy::TenantContext.new(company_id: 0) }
        .to raise_error(SemanticLayer::TenantError, /positive/)
    end

    it "is immutable once built" do
      context = Tenancy::TenantContext.new(company_id: 1)

      expect { context.instance_variable_set(:@company_id, 2) }
        .to raise_error(FrozenError)
    end
  end

  describe "the company predicate is always in the SQL" do
    it "is present even when the query asks for no filters" do
      result = layer.run({ "metrics" => ["total_reviews"] }, tenant: tenant(1))

      expect(result.meta[:sql]).to include("reviews.company_id = $1")
      expect(result.meta[:binds].first).to eq(1)
    end

    it "is applied in every JOIN too, not only in the WHERE" do
      result = layer.run({
        "metrics"    => ["total_reviews"],
        "dimensions" => ["department"]
      }, tenant: tenant(1))

      expect(result.meta[:sql])
        .to include("AND employees.company_id = reviews.company_id")
      expect(result.meta[:sql])
        .to include("AND departments.company_id = employees.company_id")
    end
  end

  describe "each company sees only its own data" do
    # Both companies have departments with THE SAME NAME on purpose: if
    # isolation ever broke, the numbers would silently blend instead of
    # producing a visible error.
    let(:query) do
      { "metrics" => ["total_reviews"], "dimensions" => ["department"] }
    end

    it "both companies name their departments identically" do
      names_a = layer.run(query, tenant: tenant(1)).data.map { |r| r["department"] }
      names_b = layer.run(query, tenant: tenant(2)).data.map { |r| r["department"] }

      expect(names_a).to match_array(names_b)
      expect(names_a).to match_array(%w[Ingeniería Ventas])
    end

    it "each company only totals its own reviews" do
      total_all = run_sql("SELECT COUNT(*) AS n FROM performance_reviews").first["n"]

      total_a = layer.run(query, tenant: tenant(1)).data.sum { |r| r["total_reviews"] }
      total_b = layer.run(query, tenant: tenant(2)).data.sum { |r| r["total_reviews"] }

      expect(total_a).to be > 0
      expect(total_b).to be > 0
      expect(total_a + total_b).to eq(total_all)
      expect(total_a).not_to eq(total_all)
    end

    it "no row of one company shows up in the other company's result" do
      foreign_ids = run_sql(<<~SQL, [1]).map { |r| r["id"] }
        SELECT r.id
        FROM performance_reviews r
        JOIN employees e ON e.id = r.employee_id
        WHERE e.company_id <> $1
      SQL

      mine = layer.run({ "metrics" => ["total_reviews"] }, tenant: tenant(1))
                  .data.first["total_reviews"]

      expect(foreign_ids).not_to be_empty
      expect(mine).to eq(run_sql(
        "SELECT COUNT(*) AS n FROM performance_reviews WHERE company_id = $1", [1]
      ).first["n"])
    end
  end

  describe "the consumer cannot touch the tenant" do
    it "rejects company_id as a dimension" do
      expect {
        layer.run({ "metrics" => ["total_reviews"], "dimensions" => ["company_id"] },
                  tenant: tenant(1))
      }.to raise_error(SemanticLayer::InvalidQueryError, /company_id/)
    end

    it "rejects company_id as a filter" do
      expect {
        layer.run({
          "metrics" => ["total_reviews"],
          "filters" => [{ "dimension" => "company_id", "operator" => "eq", "values" => [2] }]
        }, tenant: tenant(1))
      }.to raise_error(SemanticLayer::InvalidQueryError, /company_id/)
    end
  end

  describe "SQL injection" do
    it "treats a malicious payload as a value, not as SQL" do
      payload = "'; DROP TABLE employees; --"

      result = layer.run({
        "metrics" => ["total_reviews"],
        "filters" => [{ "dimension" => "review_status", "operator" => "eq",
                        "values" => [payload] }]
      }, tenant: tenant(1))

      expect(result.meta[:sql]).not_to include("DROP")
      expect(result.meta[:binds]).to include(payload)
      expect(result.data.first["total_reviews"]).to eq(0)

      # The table is still there.
      expect(run_sql("SELECT COUNT(*) AS n FROM employees").first["n"]).to be > 0
    end

    it "rejects an operator outside the allow-list" do
      expect {
        layer.run({
          "metrics" => ["total_reviews"],
          "filters" => [{ "dimension" => "review_status", "operator" => "LIKE",
                          "values" => ["%a%"] }]
        }, tenant: tenant(1))
      }.to raise_error(SemanticLayer::InvalidQueryError, /operator/)
    end
  end
end
