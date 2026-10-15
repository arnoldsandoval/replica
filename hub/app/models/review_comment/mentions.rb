# Resolves external identities before a transaction and syncs durable mention facts within it.
class ReviewComment::Mentions < ActiveRecord::AssociatedObject
  TOKEN = /(?<![A-Za-z0-9_@\/])@([A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)(?![A-Za-z0-9_-])/
  MAXIMUM_RECIPIENTS = 10

  # Resolves plain-text tokens without creating accounts or performing HTTP within a transaction.
  def self.resolve(repository:, body:, existing: [])
    logins = body.to_s.scan(TOKEN).flatten.map(&:downcase).uniq
    if logins.length > MAXIMUM_RECIPIENTS
      raise ReviewComment::TooManyMentions, "Each message can mention at most #{MAXIMUM_RECIPIENTS} distinct people"
    end
    return [] if logins.empty? || repository.local?

    configuration = GithubAppConfiguration.current
    raise GithubClient::Error, "GitHub is unavailable" if configuration.nil?

    client = configuration.github_client.repositories
    token = configuration.tokens.installation
    logins.filter_map do |login|
      previous = existing.find { _1.login.downcase == login }
      profile = if previous
        client.mention_profile(previous.github_identity.login, github_id: previous.github_identity.github_id, token:)
      else
        client.mention_profile(login, token:)
      end
      next if profile.nil?
      next if previous && profile.fetch(:github_id) != previous.github_identity.github_id

      identity = GithubIdentity.new(**profile)
      next unless repository.authorization.authorized?(identity, fresh: true, configuration:)

      profile.merge(token_login: login)
    end
  end

  # Diffs recipients under the message lock, retaining existing notifications on ordinary edits.
  def sync!(profiles)
    profiles = profiles.reject { _1.fetch(:github_id) == record.user.github_id }.uniq { _1.fetch(:github_id) }
    identities = profiles.map { GithubIdentity.record!(_1) }
    retained_ids = identities.map(&:id)
    record.comment_mentions.where.not(github_identity_id: retained_ids).destroy_all
    profiles.zip(identities).each do |profile, identity|
      mention = record.comment_mentions.find_or_initialize_by(github_identity: identity)
      added = mention.new_record?
      mention.update! login: profile.fetch(:token_login)
      Notification.record_mention!(mention) if added
    end
    record.comment_mentions.reset
  end
end
