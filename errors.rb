# errors.rb
module SemanticLayer
  # Base error: every problem in the semantic layer inherits from this, so a
  # consumer can catch them all with a single rescue.
  class Error < StandardError; end

  # --- LOAD-TIME errors (raised when the application boots) ---------------
  # The catalog could not be built: a malformed or inconsistent YAML file.
  class ValidationError < Error; end

  # --- QUERY-TIME errors (raised when a query comes in) -------------------
  class UnknownMetricError    < Error; end
  class UnknownDimensionError < Error; end
  class UnknownEntityError    < Error; end

  # The consumer asked for something it is not allowed to ask for
  # (for example, passing company_id).
  class InvalidQueryError < Error; end

  # The tenant context is missing or invalid.
  class TenantError < Error; end
end
