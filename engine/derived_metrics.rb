# engine/derived_metrics.rb
require "strscan"
require_relative "../errors"

module SemanticLayer
  module Engine
    # Metrics computed from other metrics.
    #
    # It does three things:
    #   1. Parses the formula into a tree (AST) using a CLOSED grammar: only
    #      metric references, numbers, + - * / and parentheses. Any other
    #      character blows up. This is not string interpolation, so a formula
    #      cannot become an injection vector.
    #   2. Expands dependencies: asking for 'completion_rate' pulls
    #      'completed_reviews' and 'total_reviews' into the inner SELECT.
    #   3. Renders the tree into a SQL expression over ALREADY AGGREGATED
    #      columns -- never over individual rows.
    class DerivedMetrics
      Num = Struct.new(:value)
      Ref = Struct.new(:name)
      Op  = Struct.new(:operator, :left, :right)

      # name: the metric the consumer asked for.
      # ast:  nil for a plain aggregation; the tree for a derived metric.
      Output     = Struct.new(:name, :ast, keyword_init: true)
      Resolution = Struct.new(:base_metrics, :outputs, keyword_init: true)

      def initialize(catalog)
        @catalog = catalog
      end

      # Takes the names requested by the consumer and returns:
      #   - base_metrics: the aggregations that must go in the inner SELECT
      #   - outputs:      what the outer SELECT returns, in order
      def resolve(metric_names)
        base    = []
        outputs = []

        metric_names.each do |name|
          metric = @catalog.metric!(name)

          if metric.derived?
            ast = expand(metric)
            refs(ast).each { |ref_name| add_base(base, ref_name) }
            outputs << Output.new(name: name, ast: ast)
          else
            add_base(base, name)
            outputs << Output.new(name: name, ast: nil)
          end
        end

        Resolution.new(base_metrics: base, outputs: outputs)
      end

      # Turns the tree into SQL. The block maps a metric name to the
      # aggregated column that holds it (e.g. m_total_reviews).
      def to_sql(node, &column_for)
        case node
        when Num
          # Literal from our own YAML, not user input.
          node.value
        when Ref
          column_for.call(node.name)
        when Op
          left  = to_sql(node.left, &column_for)
          right = to_sql(node.right, &column_for)

          if node.operator == "/"
            # ::numeric  -> in Postgres 3/4 between integers yields 0, not 0.75
            # NULLIF(,0) -> division by zero returns NULL instead of erroring
            "(#{left}::numeric / NULLIF(#{right}, 0))"
          else
            "(#{left} #{node.operator} #{right})"
          end
        end
      end

      private

      # If a derived metric references another derived metric, its tree is
      # substituted inline. Since the catalog already verified there are no
      # cycles, this recursion always terminates, and the resulting tree only
      # contains references to aggregation metrics.
      def expand(metric)
        inline(parse(metric.formula))
      end

      def inline(node)
        case node
        when Num then node
        when Ref
          referenced = @catalog.metric!(node.name)
          referenced.derived? ? inline(parse(referenced.formula)) : node
        when Op
          Op.new(node.operator, inline(node.left), inline(node.right))
        end
      end

      def refs(node)
        case node
        when Num then []
        when Ref then [node.name]
        when Op  then refs(node.left) + refs(node.right)
        end.uniq
      end

      def add_base(list, name)
        return if list.any? { |m| m.name == name }

        list << @catalog.metric!(name)
      end

      def parse(formula)
        Parser.new(tokenize(formula), formula).parse!
      end

      # The allow-list of what a formula may contain.
      def tokenize(formula)
        scanner = StringScanner.new(formula.to_s)
        tokens  = []

        until scanner.eos?
          scanner.skip(/\s+/)
          break if scanner.eos?

          if (number = scanner.scan(/\d+(?:\.\d+)?/))
            tokens << [:number, number]
          elsif (identifier = scanner.scan(/[a-zA-Z_][a-zA-Z0-9_]*/))
            tokens << [:identifier, identifier]
          elsif (symbol = scanner.scan(%r{[()+\-*/]}))
            tokens << [:symbol, symbol]
          else
            raise ValidationError,
                  "character not allowed in formula '#{formula}': " \
                  "'#{scanner.getch}'"
          end
        end

        tokens
      end

      # Recursive descent. The method hierarchy IS the precedence:
      # expression (+ -) calls term (* /), which calls factor.
      class Parser
        def initialize(tokens, formula)
          @tokens  = tokens
          @formula = formula
          @pos     = 0
        end

        def parse!
          node = expression

          raise ValidationError, "invalid formula: '#{@formula}'" unless @pos == @tokens.size

          node
        end

        private

        def expression
          node = term
          while symbol?("+") || symbol?("-")
            operator = advance.last
            node = Op.new(operator, node, term)
          end
          node
        end

        def term
          node = factor
          while symbol?("*") || symbol?("/")
            operator = advance.last
            node = Op.new(operator, node, factor)
          end
          node
        end

        def factor
          token = advance
          raise ValidationError, "incomplete formula: '#{@formula}'" if token.nil?

          type, value = token

          case type
          when :number     then Num.new(value)
          when :identifier then Ref.new(value)
          when :symbol
            unless value == "("
              raise ValidationError,
                    "expected a number or a metric, found '#{value}' in: '#{@formula}'"
            end

            node = expression
            unless advance == [:symbol, ")"]
              raise ValidationError, "unclosed parenthesis in: '#{@formula}'"
            end
            node
          end
        end

        def peek
          @tokens[@pos]
        end

        def advance
          token = @tokens[@pos]
          @pos += 1
          token
        end

        def symbol?(char)
          peek == [:symbol, char]
        end
      end
    end
  end
end
