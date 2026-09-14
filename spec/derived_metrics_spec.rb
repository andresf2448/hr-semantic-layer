# spec/derived_metrics_spec.rb
require_relative "spec_helper"

RSpec.describe "Derived metrics" do
  it "expands dependencies the consumer did not ask for" do
    result = layer.run({ "metrics" => ["completion_rate"] }, tenant: tenant(1))

    # completion_rate = completed_reviews / total_reviews * 100
    # Both base metrics go into the inner SELECT...
    expect(result.meta[:sql]).to include("m_completed_reviews")
    expect(result.meta[:sql]).to include("m_total_reviews")

    # ...but they are not returned, because nobody asked for them.
    expect(result.meta[:metrics]).to eq(["completion_rate"])
    expect(result.data.first.keys).to eq(["completion_rate"])
  end

  it "evaluates the formula outside the CTE, over already aggregated columns" do
    sql = layer.run({ "metrics" => ["completion_rate"] }, tenant: tenant(1)).meta[:sql]

    boundary = sql.index(")\nSELECT")
    expect(boundary).not_to be_nil

    inner = sql[0...boundary]   # the CTE: where real rows are aggregated
    outer = sql[boundary..]     # the projection: only sees aggregated columns

    expect(inner).to include("COUNT(*)")
    expect(inner).not_to include("NULLIF(m_total_reviews")

    expect(outer).to include("m_completed_reviews::numeric")
    expect(outer).to include("NULLIF(m_total_reviews, 0)")
  end

  # THE CENTRAL TEST.
  #
  # With data where employees do NOT all have the same number of reviews,
  # these two ways of computing the rate give DIFFERENT results:
  #
  #   correct   -> SUM(completed) / SUM(total)              (over aggregates)
  #   incorrect -> AVG(completed_per_employee / total_per_employee)
  #
  # The engine must match the first and differ from the second.
  it "matches the ratio of aggregates and NOT the average of ratios" do
    ours = layer.run({
      "metrics"    => ["completion_rate"],
      "dimensions" => ["department"]
    }, tenant: tenant(1)).data

    aggregate_ratio = run_sql(<<~SQL, [1])
      SELECT d.name AS department,
             COUNT(*) FILTER (WHERE r.status = 'completed')::numeric
               / NULLIF(COUNT(*), 0) * 100 AS rate
      FROM performance_reviews r
      JOIN employees   e ON e.id = r.employee_id
      JOIN departments d ON d.id = e.department_id
      WHERE r.company_id = $1
      GROUP BY 1
      ORDER BY 1
    SQL

    average_of_ratios = run_sql(<<~SQL, [1])
      SELECT department, AVG(rate) AS rate
      FROM (
        SELECT d.name AS department,
               COUNT(*) FILTER (WHERE r.status = 'completed')::numeric
                 / NULLIF(COUNT(*), 0) * 100 AS rate
        FROM performance_reviews r
        JOIN employees   e ON e.id = r.employee_id
        JOIN departments d ON d.id = e.department_id
        WHERE r.company_id = $1
        GROUP BY d.name, e.id
      ) per_employee
      GROUP BY 1
      ORDER BY 1
    SQL

    mine     = ours.sort_by { |r| r["department"] }.map { |r| r["completion_rate"].to_f.round(4) }
    correct  = aggregate_ratio.map   { |r| r["rate"].to_f.round(4) }
    mistaken = average_of_ratios.map { |r| r["rate"].to_f.round(4) }

    expect(mine).to eq(correct)

    # If this ever fails it means the seed data stopped being asymmetric and
    # the test is no longer proving anything.
    expect(correct).not_to eq(mistaken)
    expect(mine).not_to eq(mistaken)
  end

  it "guards division by zero by returning NULL instead of erroring" do
    result = layer.run({
      "metrics" => ["completion_rate"],
      "filters" => [{ "dimension" => "review_status", "operator" => "eq",
                      "values" => ["does-not-exist"] }]
    }, tenant: tenant(1))

    expect(result.meta[:sql]).to include("NULLIF")
    expect(result.data.first["completion_rate"]).to be_nil
  end

  it "forces decimal arithmetic in the division" do
    result = layer.run({ "metrics" => ["completion_rate"] }, tenant: tenant(1))

    expect(result.meta[:sql]).to include("::numeric")
    # Integer division would collapse a partial rate to 0.
    expect(result.data.first["completion_rate"].to_f).to be > 0
    expect(result.data.first["completion_rate"].to_f).to be < 100
  end

  describe "formula validation" do
    let(:parser) { SemanticLayer::Engine::DerivedMetrics.new(layer.catalog) }

    it "rejects any character outside the grammar" do
      expect { parser.send(:parse, "total_reviews; DROP TABLE employees") }
        .to raise_error(SemanticLayer::ValidationError, /not allowed/)
    end

    it "rejects an unclosed parenthesis" do
      expect { parser.send(:parse, "(total_reviews") }
        .to raise_error(SemanticLayer::ValidationError, /parenthesis/)
    end

    it "rejects an incomplete formula" do
      expect { parser.send(:parse, "total_reviews +") }
        .to raise_error(SemanticLayer::ValidationError, /incomplete/)
    end
  end
end
