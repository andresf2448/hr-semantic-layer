# llm/adapter.rb
require "json"
require_relative "../semantic_layer"
require_relative "tool_schema"
require_relative "client"

module SemanticLayer
  module LLM
    # Natural language adapter.
    #
    # It lives ON TOP of the core, never inside it: it requires
    # semantic_layer, and the core requires nothing from here. That is why
    # the core is testable without an API key or network, and why switching
    # AI provider does not touch it.
    #
    # The LLM steps in at two points, and sees SQL at neither:
    #   1. it translates the human question into the declarative JSON
    #   2. it writes the result up in prose
    class Adapter
      MAX_ATTEMPTS = 3

      # Translating a question into names from a closed list is not a creative
      # task, so greedy decoding (temperature 0) is the right call: it asks for
      # the most likely mapping instead of a sampled one. num_predict caps a
      # small model that falls into a repetition loop -- without it, a bad
      # attempt generates until it runs out of context and the run takes
      # minutes instead of seconds.
      TRANSLATION_OPTIONS = { temperature: 0, num_predict: 400 }.freeze

      # The summary is prose, where some sampling reads better. The cap keeps
      # it from rambling past the two sentences it was asked for.
      SUMMARY_OPTIONS = { num_predict: 200 }.freeze

      # More groups than this tied at one end is not a highlight, it is the
      # norm. Naming seven of them produces a fact so long that the model
      # garbles it -- it drops entries and invents a comparison to fill in.
      MAX_GROUPS = 3

      Answer = Struct.new(
        :question, :query, :attempts, :result, :summary, :provider,
        keyword_init: true
      )

      def initialize(layer:, client: OllamaClient.new)
        @layer  = layer
        @client = client
        @schema = ToolSchema.new(layer.catalog)
      end

      def ask(question, tenant:)
        attempts = []
        feedback = nil
        result   = nil
        query    = nil

        MAX_ATTEMPTS.times do |i|
          raw = nil

          begin
            raw    = @client.complete(system: system_prompt,
                                      user: user_prompt(question, feedback),
                                      json: true,
                                      options: TRANSLATION_OPTIONS)
            query  = parse_json(raw)
            result = @layer.run(query, tenant: tenant)

            attempts << { attempt: i + 1, raw: raw, query: query, error: nil }
            break
          rescue SemanticLayer::Error => e
            # The validator error LISTS the valid options, so it is handed
            # back to the model to correct itself. That is the real value of
            # actionable error messages.
            attempts << { attempt: i + 1, raw: raw, query: query, error: e.message }
            feedback = e.message
            result   = nil
          end
        end

        if result.nil?
          last = attempts.last
          raise Error,
                "The model failed to produce a valid query in " \
                "#{MAX_ATTEMPTS} attempts.\n" \
                "Last error: #{last[:error]}\n" \
                "Last model response: #{last[:raw].to_s[0, 400]}"
        end

        Answer.new(
          question: question,
          query:    query,
          attempts: attempts,
          result:   result,
          summary:  summarize(question, result),
          provider: @client.name
        )
      end

      private

      # The prompt teaches the shape with EXAMPLES rather than with a formal
      # schema: small models follow a concrete pattern far better than a
      # specification. The closed list of valid names still comes straight
      # from the catalog (ToolSchema#catalog_listing), so the model can only
      # pick from what actually exists.
      #
      # The prompt itself stays in Spanish: the end user asks in Spanish and
      # the model must answer in Spanish.
      def system_prompt
        <<~PROMPT
          Traduces preguntas de negocio en español a un objeto JSON.
          NO escribes SQL y no conoces la base de datos.

          #{@schema.catalog_listing}

          FORMATO DE RESPUESTA (devuelve SOLO el objeto JSON, sin explicaciones):
          {"metrics": ["..."], "dimensions": ["..."], "filters": [...]}

          EJEMPLO 1
          Pregunta: ¿cuántas evaluaciones se completaron por departamento?
          Respuesta: {"metrics":["completed_reviews"],"dimensions":["department"]}

          EJEMPLO 2
          Pregunta: score promedio de desempeño por trimestre durante 2025
          Respuesta: {"metrics":["avg_performance_score"],"dimensions":[{"name":"review_period","granularity":"quarter"}],"filters":[{"dimension":"review_period","operator":"between","values":["2025-01-01","2025-12-31"]}]}

          EJEMPLO 3
          Pregunta: tasa de completitud por departamento y trimestre en 2025
          Respuesta: {"metrics":["completion_rate"],"dimensions":["department",{"name":"review_period","granularity":"quarter"}],"filters":[{"dimension":"review_period","operator":"between","values":["2025-01-01","2025-12-31"]}]}

          EJEMPLO 4
          Pregunta: días presentes por semana en enero de 2025
          Respuesta: {"metrics":["present_days"],"dimensions":[{"name":"attendance_date","granularity":"week"}],"filters":[{"dimension":"attendance_date","operator":"between","values":["2025-01-01","2025-01-31"]}]}

          REGLAS
          - "metrics" es obligatorio y NUNCA puede ir vacío.
          - Una pregunta trata de UN solo tema: o evaluaciones de desempeño o
            asistencia. Nunca mezcles métricas de los dos.
          - Para fechas de asistencia usa attendance_date; para periodos de
            evaluación usa review_period. No los intercambies.
          - Usa únicamente nombres de las listas de arriba, tal cual están escritos.
          - "granularity" solo en dimensiones que declaren granularidades.
          - NUNCA incluyas company_id: el aislamiento por empresa es automático.
        PROMPT
      end

      def user_prompt(question, feedback)
        return question if feedback.nil?

        <<~PROMPT
          #{question}

          Tu respuesta anterior fue rechazada con este error:
          #{feedback}

          Corrígela usando solo nombres de la lista.
        PROMPT
      end

      # The model writes prose but NEVER a number.
      #
      # Two rounds of testing with a small local model showed why: handed the
      # result table it restated it with rows misaligned; handed only
      # pre-computed figures it still confabulated others. A wrong number in
      # the summary silently contradicts the table printed right above it.
      #
      # So the model is given no figures at all -- only WHICH group stands
      # out and which lags, computed in Ruby -- and is told not to write
      # numbers. The figures live in the table, where they are guaranteed
      # correct. The model does the one thing it does better than code:
      # phrase something readably.
      def summarize(question, result)
        facts = highlights(result)
        return "Sin resultados para esta pregunta." if facts.empty?

        @client.complete(
          system: <<~PROMPT,
            Redactas hallazgos de analítica de recursos humanos en español,
            para alguien de negocio.

            REGLAS ESTRICTAS:
            - NO escribas NINGÚN número, porcentaje ni cifra. Ninguno.
              La tabla con los datos ya está a la vista del usuario.
            - Usa ÚNICAMENTE los hechos que te entrego. No agregues otros.
            - Máximo 2 frases, en prosa. No hagas listas.
            - Describe qué destaca y qué se queda atrás, en palabras.
          PROMPT
          user: "Pregunta: #{question}\n\nHechos:\n#{facts.join("\n")}",
          options: SUMMARY_OPTIONS
        )
      end

      # Computed in Ruby, deterministically, from the rows the database
      # returned. Deliberately carries NO numeric values: it names the groups
      # that stand out, not their figures.
      def highlights(result)
        rows = result.data
        return [] if rows.empty?

        dimensions = result.meta[:dimensions]
        return ["Se obtuvo un único resultado agregado."] if dimensions.empty?

        result.meta[:metrics].filter_map do |metric|
          present = rows.reject { |row| row[metric].nil? }
          next if present.size < 2

          values = present.map { |row| row[metric].to_f }
          top    = values.max
          bottom = values.min

          # Every group scored the same: there is nothing to point out.
          next if top == bottom

          # ALL the tied groups, not just the first one. max_by/min_by pick a
          # single winner out of a tie silently, which would hand the model a
          # fact that is false -- and the model would faithfully write it down.
          leaders  = groups_at(present, metric, top, dimensions)
          laggards = groups_at(present, metric, bottom, dimensions)

          label = label_for(metric)

          if leaders.size <= MAX_GROUPS && laggards.size <= MAX_GROUPS
            "En '#{label}' #{verb(leaders, 'destaca')} #{enumerate(leaders)} " \
            "y #{verb(laggards, 'queda')} atrás #{enumerate(laggards)}."
          elsif leaders.size <= MAX_GROUPS
            "En '#{label}' #{verb(leaders, 'destaca')} #{enumerate(leaders)}; " \
            "el resto queda por debajo."
          elsif laggards.size <= MAX_GROUPS
            "En '#{label}' #{verb(laggards, 'queda')} atrás #{enumerate(laggards)}; " \
            "el resto está por encima."
          end
          # Both ends crowded: nothing stands out, so filter_map drops it.
        end
      end

      def groups_at(rows, metric, value, dimensions)
        rows.select { |row| row[metric].to_f == value }
            .map     { |row| group_of(row, dimensions) }
      end

      # destaca/destacan, queda/quedan.
      def verb(items, singular)
        items.size > 1 ? "#{singular}n" : singular
      end

      # "A" / "A y B" / "A, B y C". A chain of "y" reads as a single item and
      # the model rephrases it into something that contradicts the table.
      def enumerate(items)
        return items.first.to_s if items.size == 1

        "#{items[0..-2].join(', ')} y #{items.last}"
      end

      def label_for(metric)
        @layer.catalog.metric(metric)&.label || metric
      end

      # The first dimension names the group; the rest qualify it in
      # parentheses, so commas inside a group are never confused with the
      # commas that separate one group from the next.
      def group_of(row, dimensions)
        values = dimensions.map { |name| row[name] }.compact
        return values.first.to_s if values.size <= 1

        "#{values.first} (#{values[1..].join(', ')})"
      end

      # Some models wrap the JSON in ```json ... ```, so the fences are
      # stripped before parsing.
      def parse_json(raw)
        cleaned = raw.to_s.gsub(/\A```(?:json)?\s*/, "").gsub(/```\s*\z/, "").strip
        JSON.parse(cleaned)
      rescue JSON::ParserError
        raise Error, "The model did not return valid JSON: #{raw.to_s[0, 200]}"
      end
    end
  end
end
