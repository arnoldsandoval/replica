require "bundler"
require "json"

module DependencyAgePolicy
  # Reads repository lockfiles and Action definitions into one dependency list.
  class DependencyLoader
    def initialize(root:, excluded_paths: [])
      @root = File.expand_path(root)
      @excluded_paths = excluded_paths.map { |path| File.expand_path(path, @root) }
    end

    # Returns unique dependencies and any invalid Action references found while loading.
    def call
      dependencies = npm_dependencies + gem_dependencies
      action_dependencies, action_failures = github_action_dependencies

      [ deduplicate(dependencies + action_dependencies), action_failures ]
    end

    private

    def deduplicate(dependencies)
      dependencies
        .group_by { |dependency| [ dependency.ecosystem, dependency.name, dependency.version, dependency.platform ] }
        .map do |(_, name, version, platform), copies|
          Dependency.new \
            ecosystem: copies.first.ecosystem,
            name:,
            version:,
            platform:,
            source: copies.map(&:source).uniq.sort.join(", ")
        end
    end

    def npm_dependencies
      Dir[File.join(@root, "**/package-lock.json")]
        .reject { |path| path.include?("/node_modules/") || excluded?(path) }
        .flat_map { |path| npm_dependencies_from(path) }
    end

    def npm_dependencies_from(path)
      lockfile = JSON.parse(File.read(path))

      lockfile.fetch("packages", {}).filter_map do |package_path, package|
        next unless package_path.include?("node_modules/")
        next if package["link"] || !package["version"]

        Dependency.new \
          ecosystem: "npm",
          name: package["name"] || npm_package_name(package_path),
          version: package.fetch("version"),
          platform: nil,
          source: relative_path(path)
      end
    end

    def npm_package_name(package_path)
      tail = package_path.split("node_modules/").last
      return tail.split("/").first(2).join("/") if tail.start_with?("@")

      tail.split("/").first
    end

    def gem_dependencies
      Dir[File.join(@root, "**/Gemfile.lock")]
        .reject { |path| path.include?("/vendor/") || path.include?("/.ruby-lsp/") || excluded?(path) }
        .flat_map { |path| gem_dependencies_from(path) }
    end

    def gem_dependencies_from(path)
      parser = Bundler::LockfileParser.new(Bundler.read_file(path))
      dependencies = parser.specs.map do |spec|
        Dependency.new \
          ecosystem: "bundler",
          name: spec.name,
          version: spec.version.to_s,
          platform: spec.platform.to_s,
          source: relative_path(path)
      end

      if parser.bundler_version
        dependency = Dependency.new \
          ecosystem: "bundler",
          name: "bundler",
          version: parser.bundler_version.to_s,
          platform: "ruby",
          source: relative_path(path)
        dependencies << dependency
      end

      dependencies
    end

    def github_action_dependencies
      dependencies = []
      failures = []

      action_definition_paths.each do |path|
        File.foreach(path).with_index(1) do |line, line_number|
          match = line.match(/^\s*(?:-\s+)?uses:\s+([^\s#]+)/)
          next unless match

          reference = unquote(match[1])
          next if reference.start_with?("./")

          name, version = reference.split("@", 2)
          dependency = Dependency.new \
            ecosystem: "github-actions",
            name:,
            version: version || "(missing)",
            platform: nil,
            source: "#{relative_path(path)}:#{line_number}"

          if version&.match?(/\A[0-9a-f]{40}\z/)
            dependencies << dependency
          else
            failures << Failure.new(dependency:, message: "external actions must use a full commit SHA")
          end
        end
      end

      [ dependencies, failures ]
    end

    def action_definition_paths
      patterns = [
        File.join(@root, ".github/workflows/**/*.{yml,yaml}"),
        File.join(@root, "actions/**/*.{yml,yaml}")
      ]

      patterns
        .flat_map { |pattern| Dir[pattern] }
        .reject { |path| path.include?("/node_modules/") || excluded?(path) }
        .uniq
    end

    def unquote(reference)
      quote = reference[0]
      return reference unless [ "'", "\"" ].include?(quote) && reference.end_with?(quote)

      reference[1...-1]
    end

    def relative_path(path)
      path.delete_prefix("#{@root}/")
    end

    def excluded?(path)
      @excluded_paths.any? { |excluded_path| path == excluded_path || path.start_with?("#{excluded_path}/") }
    end
  end
end
