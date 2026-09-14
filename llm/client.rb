# llm/client.rb
require "json"
require "net/http"
require "uri"
require_relative "../errors"

module SemanticLayer
  module LLM
    # Talks to a local model through Ollama. No API key, no account and no
    # new gems: just net/http from the standard library.
    #
    # The adapter receives this client as a parameter, it does not build it.
    # That is why switching AI provider means writing another class with the
    # same `complete` method and touching nothing else.
    class OllamaClient
      DEFAULT_HOST  = "http://localhost:11434"
      DEFAULT_MODEL = "llama3.2:3b"

      def initialize(host: ENV.fetch("OLLAMA_HOST", DEFAULT_HOST),
                     model: ENV.fetch("OLLAMA_MODEL", DEFAULT_MODEL))
        @host  = host
        @model = model
      end

      def name
        "ollama:#{@model}"
      end

      # json: true forces the model to answer with valid JSON. Ollama
      # guarantees it at decoding level, not by trusting the prompt.
      def complete(system:, user:, json: false, options: {})
        uri  = URI("#{@host}/api/chat")
        body = {
          model: @model,
          stream: false,
          messages: [
            { role: "system", content: system },
            { role: "user",   content: user }
          ]
        }
        body[:format]  = "json" if json
        body[:options] = options unless options.empty?

        request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
        request.body = JSON.generate(body)

        response =
          begin
            Net::HTTP.start(uri.hostname, uri.port, read_timeout: 120) do |http|
              http.request(request)
            end
          rescue Errno::ECONNREFUSED, SocketError
            raise Error,
                  "Could not connect to Ollama at #{@host}. " \
                  "Check that it is running ('ollama serve')."
          end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "Ollama responded #{response.code}: #{response.body}"
        end

        JSON.parse(response.body).dig("message", "content").to_s
      end
    end
  end
end
