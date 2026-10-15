# Validates the reviewed Action pin before Hub uses it for repository workflows.
class BuildActionReleases
  ACTION_REF = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}\z}
  REVISION = /\A[0-9a-f]{40}\z/

  # Rejects a broken source pin even when an operator overrides it.
  def self.parse(lines)
    if !lines.first&.match?(ACTION_REF) || lines.drop(1).any? { !_1.match?(REVISION) }
      raise "Invalid build Action release list"
    end

    lines
  end
end
