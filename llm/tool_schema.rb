# llm/tool_schema.rb
module SemanticLayer
  module LLM
    # Turns the catalog into the contract handed to an LLM.
    #
    # This class is why the AI agent is safe: the model is not told "write a
    # query", it is told "pick from this closed list". Its error space goes
    # from infinite to a finite, validatable set.
    #
    # It depends on no AI provider: it is a pure transformation of the
    # catalog, testable without network access or an API key.
    class ToolSchema
      def initialize(catalog)
        @catalog = catalog
      end

      # Compact listing with the Spanish business labels: the bridge between
      # the human question ("cómo va el desempeño") and the technical name
      # (avg_performance_score). Without it the model would have to guess.
      #
      # It is regenerated from the catalog on every call, so adding a metric
      # to a YAML file is enough for the model to know it exists.
      def catalog_listing
        described = @catalog.describe

        metrics = described[:metrics].map do |m|
          unit = m[:unit] ? " (#{m[:unit]})" : ""
          "  - #{m[:name]}: #{m[:label]}#{unit}"
        end

        dimensions = described[:dimensions].map do |d|
          granularity =
            d[:granularities].empty? ? "" : " [granularidades: #{d[:granularities].join(', ')}]"
          "  - #{d[:name]}: #{d[:label]}#{granularity}"
        end

        "MÉTRICAS DISPONIBLES:\n#{metrics.join("\n")}\n\n" \
        "DIMENSIONES DISPONIBLES:\n#{dimensions.join("\n")}"
      end
    end
  end
end
