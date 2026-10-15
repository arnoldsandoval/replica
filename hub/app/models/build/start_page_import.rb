require "base64"
require "open3"

# Seeds a Prototype once from configuration at an immutable Build commit.
class Build::StartPageImport < ActiveRecord::AssociatedObject
  MAXIMUM_FILE_BYTES = 16_384
  class InvalidFile < StandardError; end

  # Missing and invalid files can be corrected by a later commit without blocking Builds.
  def fetch!(configuration: GithubAppConfiguration.current)
    build.reload
    prototype = build.prototype.reload
    repository = prototype.repository
    return if build.start_page_checked_at.present? || prototype.start_page_set_at.present?
    return unless importable?(prototype)
    return if repository.installation_state != "active"
    return if !repository.local? && (configuration.nil? || configuration.installation_state != "active")

    content = repository.local? ? local_content(repository) : github_content(repository, configuration)
    start_page = parse(content) unless content.nil?
    prototype.with_lock do
      return unless importable?(prototype)

      prototype.update!(start_page:, start_page_set_at: Time.current) if start_page
      prototype.update!(start_page_import_error: nil)
      build.update!(start_page_checked_at: Time.current)
    end
  rescue InvalidFile, ActiveRecord::RecordInvalid => error
    message = I18n.t("prototype_management.show.start_page_import_error")
    Rails.logger.warn("Prototype #{prototype.id}: #{message} (#{error.class})")
    prototype.reload.with_lock do
      return unless importable?(prototype)

      prototype.update!(start_page_import_error: message)
      build.update!(start_page_checked_at: Time.current)
    end
  end

  private

  # Delayed jobs from an older branch head cannot claim the setting.
  def importable?(prototype)
    return false unless prototype.reviewable?

    head = prototype.current_build_id || prototype.builds.chronological.first&.id
    prototype.start_page_set_at.nil? && head == build.id
  end

  # Reads repository content with the existing installation-scoped GitHub client.
  def github_content(repository, configuration)
    token = configuration.tokens.installation
    begin
      file = configuration.github_client.repositories.content(repository, ".prototype", ref: build.commit_sha, token:)
    rescue GithubClient::NotFound
      return nil
    end
    unless file.is_a?(Hash) && file["type"] == "file" && file["encoding"] == "base64" &&
        file["size"].is_a?(Integer) && file["size"].between?(1, MAXIMUM_FILE_BYTES) &&
        file["content"].is_a?(String) && file["content"].bytesize <= MAXIMUM_FILE_BYTES * 2
      raise InvalidFile
    end
    Base64.strict_decode64(file["content"].delete("\n")).force_encoding(Encoding::UTF_8)
  rescue ArgumentError
    raise InvalidFile
  end

  # Uses only committed blobs, never the local Hub checkout's working-tree files.
  def local_content(repository)
    unless LocalDevelopment.enabled? &&
        LocalDevelopment.repository_available?(repository.local_path, identity: repository.local_identity)
      raise LocalDevelopment::Error, "Local repository is no longer configured"
    end
    return nil if on_default_branch?(repository)

    entry = Repository::LocalDiscovery.git!("-C", repository.local_path, "ls-tree", build.commit_sha, "--", ".prototype")
    return nil if entry.empty?

    mode, type, sha = entry.split(/\s+/, 4)
    raise InvalidFile unless %w[100644 100755].include?(mode) && type == "blob"

    size = Repository::LocalDiscovery.git!("-C", repository.local_path, "cat-file", "-s", sha).to_i
    raise InvalidFile unless size.between?(1, MAXIMUM_FILE_BYTES)

    content, error, status = Open3.capture3("git", "-C", repository.local_path, "cat-file", "blob", sha)
    raise LocalDevelopment::Error, "Git failed: #{error.strip}" unless status.success?

    content.force_encoding(Encoding::UTF_8)
  end

  # A branch with no commits of its own still holds the default branch's file, which names the
  # default's page. Agents often create the branch before committing, and Hub can see it then, so
  # the branch's first commit of its own decides instead, as with a missing file. Git exits 1 when
  # the commit is not on the default branch; any other failure, such as a renamed default branch,
  # raises so the job retries instead of importing the default's page for good.
  def on_default_branch?(repository)
    default = repository.default_branch
    return false if default.blank? || build.prototype.branch_name == default

    _output, error, status = Open3.capture3 \
      "git", "-C", repository.local_path, "merge-base", "--is-ancestor", build.commit_sha, "refs/heads/#{default}"
    case status.exitstatus
    when 0 then true
    when 1 then false
    else raise LocalDevelopment::Error, "Git failed: #{error.strip}"
    end
  end

  # Legacy fields are ignored; only the route is imported.
  def parse(content)
    raise InvalidFile unless content.bytesize <= MAXIMUM_FILE_BYTES && content.valid_encoding?

    data = JSON.parse(content)
    value = data["startPage"] if data.is_a?(Hash)
    raise InvalidFile unless value.is_a?(String) && value.start_with?("/") && !value.start_with?("//")
    raise InvalidFile if value.match?(/[[:cntrl:][:space:]]/)

    value
  rescue JSON::ParserError
    raise InvalidFile
  end
end
