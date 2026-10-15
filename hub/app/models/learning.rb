# Connects Hub to the replica-learning command, which owns the learning contracts and rules.
#
# Hub never decides what a team learns. It runs replica-learning with an allowlisted environment
# and reads its JSON output, so the store's consent, approval, and lifecycle rules stay the only
# rules. The command runs in Node.js; the production image installs it outside the app.
module Learning
  # Learning runs and the removal of deleted comments take turns across Hub, one at a time. A run
  # that imports or labels a comment while its text is being removed could store that text again.
  # ExecutionLock protects actual work even after a queue semaphore expires.
  CONCURRENCY = { group: "learning", key: "stores" }.freeze

  # A replica-learning command failed, timed out, or reported a rule the request broke.
  class Error < StandardError
    attr_reader :code, :labeling_result

    # Keeps known labeling usage even when the command could not finish its work.
    def initialize(message, code: "learning_failed", labeling_result: nil)
      notes = %w[progressError cleanupError usageError].filter_map { labeling_result&.fetch(_1, nil) }
        .uniq.reject { _1 == message }
      message = [ *notes, message ].join(" ") if notes.any?
      super(message)
      @code = code
      @labeling_result = labeling_result
    end
  end

  # The command Hub runs: REPLICA_LEARNING_CLI, or the copy in this repository during development.
  def self.cli_path
    Pathname(ENV.fetch("REPLICA_LEARNING_CLI", Rails.root.join("../packages/learning/bin/replica-learning.mjs").to_s))
  end

  # Whether Hub shows and changes this repository's learnings. Learnings is on while a Hub
  # administrator keeps Copilot connected, even after Copilot refused its token, so people
  # can still decide on suggestions and agents still get accepted learnings. Local development
  # has no connection and uses the developer's own Copilot sign-in for its local repositories.
  def self.available_for?(repository)
    return false if !File.file?(cli_path)

    LocalDevelopment.enabled? ? repository.local? : CopilotConnection.exists?
  end

  # Names a Hub user as the person deciding. The local identity is not a proven GitHub account,
  # so it is recorded as a person named by its Hub login rather than as github:<login>.
  def self.person_for(user)
    user.github_id ? "github:#{user.login}" : "human:#{user.login}"
  end
end
