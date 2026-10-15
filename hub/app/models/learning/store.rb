# Keeps one repository's learning data in Hub's storage and runs replica-learning against it.
#
# Each repository has its own directory under REPLICA_LEARNING_ROOT, storage/learning by default,
# outside every checkout. Its scope names the repository by a stable ID, so renaming or
# transferring the repository keeps its learnings. Hub writes the store's config.json once and
# then leaves it to the operator. That file marks the directory as a store, because an operator
# may switch the provider there, and each provider keeps its data in files of its own.
class Learning::Store
  # Every signal about what a prototype shows or does. Copilot files a missing form label under
  # usability as often as under accessibility, so enabling only some would drop real themes.
  SIGNALS = %w[visual_quality accessibility usability content interaction].freeze
  # Comments are evidence for review, and accepted learnings become instructions for agents.
  PURPOSES = %w[review instruction].freeze
  SOURCE = "hub_review_comments".freeze

  attr_reader :repository

  def initialize(repository)
    @repository = repository
  end

  # Where this repository's learning data lives.
  def directory
    validate_directory!(Rails.configuration.x.learning_root.join("repositories", repository.id.to_s))
  end

  # Whether Hub has set up this store, which it does before a run first uses it. A store with
  # nothing in it yet reads as empty, whichever provider its configuration names.
  def exist?
    directory.join("config.json").file?
  end

  # The host/owner/name replica-learning records with every item in this store.
  def scope
    return "local/repositories/#{repository.id}" if repository.local?

    "#{URI(Rails.configuration.x.github_url).host.downcase}/repositories/#{repository.github_id}"
  end

  # Runs one replica-learning command against this store and returns its JSON output.
  def call(*arguments, **options)
    command(*arguments, **options).call
  end

  # One replica-learning command against this store, ready to run, such as on another thread. It
  # resolves everything Hub needs before it runs.
  def command(*arguments, timeout: Learning::Command::TIMEOUT, copilot_token: nil)
    runner = Learning::Command.new(timeout:)
    path = directory
    arguments = [ *arguments, "--dir", path.to_s, "--repository", scope ]
    -> do
      validate_directory!(path)
      runner.call(*arguments, copilot_token:)
    end
  end

  # Creates the directory, and a config.json with Hub's defaults, when they are missing. An
  # existing config.json stays as the operator left it. replica-learning refuses a directory
  # other users can read, so Hub keeps its own private.
  def prepare!
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, directory)
    config = directory.join("config.json")
    return if config.exist?

    File.write(config, "#{JSON.pretty_generate(default_config)}\n", perm: 0o600)
  rescue SystemCallError => error
    raise Learning::Error.new \
      "Hub could not prepare this repository's learning store: #{error.message}",
      code: "unavailable"
  end

  # Active review grants for import, once the store's active grants together permit both purposes.
  # Records the initial grant only. Renewing withdrawn or expired consent needs an explicit grant.
  def grant_ids!(by:, basis:)
    grants = call("grants", "list").select { Array(_1.dig("grant", "sources")).include?(SOURCE) }
    active = grants.reject { _1["expired"] }
    purposes = active.flat_map { Array(_1["activePurposes"]) }.uniq
    if (PURPOSES - purposes).empty?
      return active.filter_map do |item|
        item.dig("grant", "id") if Array(item["activePurposes"]).include?("review")
      end
    end

    if grants.any?
      raise Learning::Error.new \
        "Consent to use this repository's review comments ended. An operator must record an explicit renewal with replica-learning grants add.",
        code: "grant_inactive"
    end

    added = call \
      "grants", "add",
      *PURPOSES.flat_map { [ "--purpose", _1 ] },
      "--source", SOURCE,
      "--basis=#{basis}",
      "--by", by
    [ added.fetch("id") ]
  end

  # Removes the text of every stored version of one Hub comment, and of the labels on them, as the
  # given person. It imports and labels nothing and needs no grant, so it adds nothing else to the
  # store, and running it again changes nothing. Hub creates no store for a repository without one.
  def remove_comment!(comment_id, by:)
    return if !exist?

    call("redact", "--comment", comment_id.to_s, "--by", by)
  end

  private

  # Rechecks captured command paths too, before a delayed command starts.
  def validate_directory!(path)
    PrivateStorageRoot.validate!(path, name: "REPLICA_LEARNING_ROOT", application_root: Rails.root, public_root: Rails.public_path)
    path
  rescue PrivateStorageRoot::Invalid, SystemCallError => error
    raise Learning::Error.new("Hub could not access this repository's learning store: #{error.message}", code: "unavailable")
  end

  # Local development signs everyone in as one identity, so a theme there has one reviewer.
  def default_config
    options = { signals: SIGNALS }
    options[:minReviewers] = 1 if repository.local?
    { schemaVersion: "replica.learning-config/v1", consolidation: { options: } }
  end
end
