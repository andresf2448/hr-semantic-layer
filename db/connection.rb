require "active_record"

ActiveRecord::Base.establish_connection(
  adapter: "postgresql",
  database: ENV.fetch("BUK_DB_NAME", "buk_semantic_layer_dev")
)