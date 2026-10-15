require "json"
require "net/http"
require "open3"
require "openssl"
require "tmpdir"
require "uri"

module DependencyAgePolicy
  # Fetches authoritative publication metadata from each ecosystem's service.
  class RegistryClient
    def initialize
      @cache = {}
      @cache_mutex = Mutex.new
    end

    # Looks up the timestamp that determines when a dependency became eligible.
    def published_at(dependency)
      case dependency.ecosystem
      when "npm"
        npm_published_at(dependency)
      when "bundler"
        gem_published_at(dependency)
      when "github-actions"
        action_published_at(dependency)
      else
        raise "unsupported ecosystem #{dependency.ecosystem.inspect}"
      end
    end

    private

    def npm_published_at(dependency)
      metadata = cached_json \
        [ "npm", dependency.name ],
        URI("https://registry.npmjs.org/#{URI.encode_www_form_component(dependency.name)}")
      published_at = metadata.dig("time", dependency.version)
      raise VerificationError, "publication time is unavailable" unless published_at

      parse_time(published_at)
    end

    def gem_published_at(dependency)
      releases = cached_json \
        [ "bundler", dependency.name ],
        URI("https://rubygems.org/api/v1/versions/#{URI.encode_www_form_component(dependency.name)}.json")
      candidates = releases.select { |release| release["number"] == dependency.version }
      release = candidates.find { |candidate| candidate["platform"].to_s == dependency.platform }
      raise VerificationError, "publication time is unavailable" unless release&.fetch("created_at", nil)

      parse_time(release.fetch("created_at"))
    end

    def action_published_at(dependency)
      owner, repository = dependency.name.split("/").first(2)
      valid_name = owner&.match?(/\A[\w.-]+\z/) && repository&.match?(/\A[\w.-]+\z/)
      raise VerificationError, "repository name is invalid" unless valid_name

      cached_value([ "github-actions", owner, repository, dependency.version ]) do
        Dir.mktmpdir("dependency-age-action") do |directory|
          run_git!("init", "--bare", directory)
          run_git! \
            "--git-dir",
            directory,
            "fetch",
            "--quiet",
            "--depth=1",
            "https://github.com/#{owner}/#{repository}.git",
            dependency.version
          published_at = run_git! \
            "--git-dir",
            directory,
            "show",
            "--no-patch",
            "--format=%cI",
            "FETCH_HEAD"
          published_at = published_at.strip
          raise VerificationError, "commit time is unavailable" if published_at.empty?

          parse_time(published_at)
        end
      end
    end

    def cached_json(key, uri)
      cached_value(key) do
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.request(Net::HTTP::Get.new(uri))
        end
        unless response.is_a?(Net::HTTPSuccess)
          raise VerificationError, "#{uri.host} returned #{response.code} #{response.message}"
        end

        JSON.parse(response.body)
      end
    rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, SocketError, SystemCallError => error
      raise VerificationError, error.message
    end

    def cached_value(key)
      @cache_mutex.synchronize { return @cache[key] if @cache.key?(key) }

      value = yield
      @cache_mutex.synchronize { @cache[key] ||= value }
    end

    def run_git!(*arguments)
      stdout, stderr, status = Open3.capture3("git", *arguments)
      message = stderr.strip
      message = "git command failed" if message.empty?
      raise VerificationError, message unless status.success?

      stdout
    rescue SystemCallError => error
      raise VerificationError, error.message
    end

    def parse_time(value)
      Time.parse(value).utc
    rescue ArgumentError => error
      raise VerificationError, "publication time is invalid: #{error.message}"
    end
  end
end
