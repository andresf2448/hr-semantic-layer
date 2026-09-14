# spec/correctness_spec.rb
require_relative "spec_helper"

RSpec.describe "Generated SQL correctness" do
  # The reference SQL from section 5 of the brief, exactly as given. Only the
  # company_id was parameterized and an ORDER BY on the department name added
  # so the row-by-row comparison is deterministic.
  REFERENCE_SQL = <<~SQL.freeze
    SELECT
      DATE_TRUNC('quarter', r.period)::date AS quarter,
      d.name                                AS department,
      COUNT(*)                              AS completed_reviews,
      AVG(r.score)                          AS avg_score
    FROM performance_reviews r
    INNER JOIN employees e
      ON e.id = r.employee_id
    INNER JOIN departments d
      ON d.id = e.department_id
    WHERE r.company_id = $1
      AND r.status = 'completed'
      AND r.period >= '2025-01-01'
      AND r.period <= '2025-12-31'
    GROUP BY 1, 2
    ORDER BY 1, 2
  SQL

  # The same question expressed declaratively: no tables, no columns, no
  # JOINs and no company_id.
  DECLARATIVE_QUERY = {
    "metrics" => %w[completed_reviews avg_performance_score],
    "dimensions" => [
      { "name" => "review_period", "granularity" => "quarter" },
      "department"
    ],
    "filters" => [
      { "dimension" => "review_period", "operator" => "between",
        "values" => %w[2025-01-01 2025-12-31] }
    ],
    "order_by" => [{ "field" => "review_period" }, { "field" => "department" }]
  }.freeze

  [1, 2].each do |company_id|
    it "matches the reference SQL row by row (company #{company_id})" do
      ours      = layer.run(DECLARATIVE_QUERY, tenant: tenant(company_id)).data
      reference = run_sql(REFERENCE_SQL, [company_id])

      expect(ours.size).to eq(reference.size)
      expect(ours).not_to be_empty

      ours.zip(reference).each do |mine, ref|
        expect(mine["review_period"]).to     eq(ref["quarter"])
        expect(mine["department"]).to        eq(ref["department"])
        expect(mine["completed_reviews"]).to eq(ref["completed_reviews"])
        expect(mine["avg_performance_score"].to_f.round(6))
          .to eq(ref["avg_score"].to_f.round(6))
      end
    end
  end

  it "resolves JOINs from the definitions, not from the query" do
    result = layer.run(DECLARATIVE_QUERY, tenant: tenant(1))

    expect(result.meta[:join_path]).to eq(
      ["performance.reviews", "core.employees", "core.departments"]
    )
    expect(result.meta[:sql]).to include("INNER JOIN employees")
    expect(result.meta[:sql]).to include("INNER JOIN departments")
  end

  it "generates no JOIN when the base entity is enough" do
    result = layer.run({ "metrics" => ["total_reviews"] }, tenant: tenant(1))

    expect(result.meta[:join_path]).to eq(["performance.reviews"])
    expect(result.meta[:sql]).not_to include("JOIN")
  end

  # This is the case the reference SQL CANNOT solve: with status = 'completed'
  # in the global WHERE, both metrics would return the same number. With a
  # per-metric FILTER (WHERE ...) they coexist in a single query.
  it "distinguishes metrics with different filters in the same query" do
    result = layer.run({
      "metrics"    => %w[completed_reviews total_reviews],
      "dimensions" => ["department"]
    }, tenant: tenant(1))

    row = result.data.find { |r| r["department"] == "Ingeniería" }

    expect(row["completed_reviews"]).to be < row["total_reviews"]
    expect(result.meta[:sql]).to include("FILTER (WHERE")
  end

  it "parameterizes every user supplied value" do
    result = layer.run(DECLARATIVE_QUERY, tenant: tenant(1))

    expect(result.meta[:sql]).to include("$1", "$2", "$3")
    expect(result.meta[:sql]).not_to include("2025-01-01")
    expect(result.meta[:binds]).to include("2025-01-01", "2025-12-31")
  end
end
