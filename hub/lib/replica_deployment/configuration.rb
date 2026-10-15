require "json"
require "securerandom"

module ReplicaDeployment
  # Generates the stable settings and fresh secrets required by a deployment.
  class Configuration
    HOST_LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    # Leaves room for a 19-digit Build ID and the preview subdomain.
    MAX_HOST_LENGTH = 224

    # Reports host input that cannot form the required public origins.
    class InvalidHost < StandardError; end

    # Builds configuration without depending on Rails or an existing environment.
    def self.generate(host, random: SecureRandom)
      new(host, random:).generate
    end

    # Stores the requested public host and the random source used for secrets.
    def initialize(host, random:)
      @host = host.to_s.strip.downcase
      @random = random
    end

    # Returns every generated setting in a stable order for portable formatting.
    def generate
      validate_host!

      {
        "REPLICA_HUB_ORIGIN" => "https://#{host}",
        "REPLICA_PREVIEW_ORIGIN_TEMPLATE" => "https://b{build_id}.preview.#{host}",
        "REPLICA_SHARE_PREVIEW_ORIGIN_TEMPLATE" => "https://s{build_id}.preview.#{host}",
        "REPLICA_BOOTSTRAP_SECRET" => random.urlsafe_base64(48),
        "SECRET_KEY_BASE" => random.hex(64),
        "REPLICA_DATABASE_ENCRYPTION_PRIMARY_KEY" => random.hex(32),
        "REPLICA_DATABASE_ENCRYPTION_DETERMINISTIC_KEY" => random.hex(32),
        "REPLICA_DATABASE_ENCRYPTION_KEY_DERIVATION_SALT" => random.hex(32)
      }
    end

    private

    attr_reader :host, :random

    # Rejects values that cannot safely form the Hub and wildcard preview hosts.
    def validate_host!
      labels = host.split(".", -1)
      valid = host.length <= MAX_HOST_LENGTH && labels.length >= 2 &&
        labels.all? { _1.match?(HOST_LABEL) } &&
        labels.last.match?(/[a-z]/)
      raise InvalidHost, "host must be a DNS name such as hub.example.com" if !valid
    end
  end

  # Renders generated settings without adding shell evaluation behavior.
  module Formatter
    # Reports unsupported output without masking unrelated argument errors.
    class InvalidFormat < ArgumentError; end

    module_function

    # Selects a stable machine-readable representation for hosting integrations.
    def format(configuration, name)
      case name
      when "dotenv"
        configuration.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n"
      when "json"
        JSON.pretty_generate(configuration) + "\n"
      else
        raise InvalidFormat, "format must be dotenv or json"
      end
    end
  end
end
