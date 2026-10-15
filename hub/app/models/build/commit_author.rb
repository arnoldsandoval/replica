# Records the author GitHub associates with one exact build commit.
class Build::CommitAuthor < ActiveRecord::AssociatedObject
  class << self
    # Returns active-repository Builds whose author lookup is not complete or recent.
    def missing
      Build.joins(prototype: :repository)
        .merge(Repository.active)
        .where(commit_author_checked_at: nil)
        .where(commit_author_requested_at: [ nil, ...1.hour.ago ])
    end

    # Enqueues a bounded batch of missing commit author lookups.
    def request_missing!
      missing.limit(100).find_each { new(_1).request! }
    end
  end

  # Enqueues one author lookup unless a recent request is already pending.
  def request!
    relation = Build.where(id: build.id, commit_author_checked_at: nil)
      .where(commit_author_requested_at: [ nil, ...1.hour.ago ])
    requested = relation.update_all(commit_author_requested_at: Time.current) == 1
    build.record_commit_author_later! if requested
    requested
  rescue StandardError
    build.update_column(:commit_author_requested_at, nil) if defined?(requested) && requested
    raise
  end

  # Fetches the exact commit and records its author when the repository is active.
  def fetch!(configuration: GithubAppConfiguration.current)
    build.reload
    return if build.commit_author_checked_at.present?
    return clear_request if configuration.nil? || configuration.installation_state != "active"

    repository = build.prototype.repository
    return clear_request if repository.installation_state != "active"

    client = configuration.github_client
    token = configuration.tokens.installation
    begin
      response = client.repositories.commit \
        repository,
        build.commit_sha,
        token: token
      record!(response)
    rescue GithubClient::NotFound, GithubClient::Gone
      build.update!(commit_author_checked_at: Time.current)
    rescue GithubClient::Error => error
      raise if error.status != 422

      build.update!(commit_author_checked_at: Time.current)
    rescue ArgumentError
      build.update!(commit_author_checked_at: Time.current)
    end
    clear_request
  end

  # Saves GitHub's commit author name and associated account once.
  def record!(commit)
    attributes = attributes_from(commit)
    build.with_lock do
      attributes.each do |attribute, value|
        build.public_send("#{attribute}=", value) if build.public_send(attribute).nil? && value.present?
      end
      build.commit_author_checked_at ||= Time.current
      build.save! if build.changed?
    end
  end

  # Returns the associated account's profile on the configured GitHub host.
  def profile_url
    return if build.commit_author_login.nil?

    "#{Rails.configuration.x.github_url.delete_suffix("/")}/" \
      "#{CGI.escapeURIComponent(build.commit_author_login)}"
  end

  private

  # Clears the in-flight marker after this lookup reaches a stable outcome.
  def clear_request
    build.update_column(:commit_author_requested_at, nil)
  end

  # Returns validated author attributes for this build's exact commit.
  def attributes_from(commit)
    raise ArgumentError, "GitHub returned a different commit" if commit.fetch("sha") != build.commit_sha

    name = commit.fetch("commit").fetch("author").fetch("name")
    if !name.is_a?(String) || name.strip.blank? || name.bytesize > 255
      raise ArgumentError, "GitHub returned an invalid commit author"
    end

    attributes = { commit_author_name: name }
    account = commit["author"]
    return attributes if account.nil?

    github_id = account.fetch("id").to_i
    login = account.fetch("login")
    avatar_url = account["avatar_url"]
    valid = github_id.positive? && login.is_a?(String) && login.strip.present? && login.bytesize <= 255
    valid &&= avatar_url.nil? || (avatar_url.is_a?(String) && avatar_url.bytesize <= 2048)
    raise ArgumentError, "GitHub returned an invalid commit author account" if !valid

    attributes.merge \
      commit_author_github_id: github_id,
      commit_author_login: login,
      commit_author_avatar_url: avatar_url
  rescue KeyError, TypeError
    raise ArgumentError, "GitHub returned incomplete commit author data"
  end
end
