module DependencyAgePolicy
  # Holds audit findings so callers can print one complete, actionable result.
  class Result
    attr_reader :checked_count, :cutoff, :failures, :violations

    def initialize(checked_count:, cutoff:, failures:, violations:)
      @checked_count = checked_count
      @cutoff = cutoff
      @failures = failures
      @violations = violations
    end

    # A check passes only when every dependency has known, old-enough metadata.
    def success?
      violations.empty? && failures.empty?
    end

    # Formats findings consistently for local runs and GitHub Actions logs.
    def to_s
      return "Dependency age policy passed for #{checked_count} dependencies." if success?

      lines = [ "Dependency age policy failed. Versions must be published on or before #{cutoff.iso8601}." ]

      violations.each do |violation|
        dependency = violation.dependency
        lines << "- #{identity(dependency)} was published at #{violation.published_at.iso8601} (#{dependency.source})"
      end

      failures.each do |failure|
        lines << "- #{identity(failure.dependency)} could not be verified: #{failure.message} (#{failure.dependency.source})"
      end

      lines.join("\n")
    end

    private

    def identity(dependency)
      "#{dependency.ecosystem}:#{dependency.name}@#{dependency.version}"
    end
  end
end
