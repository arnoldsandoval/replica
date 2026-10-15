# Owns one-use browser state and GitHub OAuth admission for this Hub.
class GithubAppConfiguration::Oauth < ActiveRecord::AssociatedObject
  MAXIMUM_AGE = 15.minutes

  class InvalidState < StandardError; end

  # Starts OAuth with state and PKCE values kept in the encrypted browser session.
  def authorize_url(browser_session)
    state = SecureRandom.urlsafe_base64(32)
    verifier = SecureRandom.urlsafe_base64(64)
    browser_session[:github_oauth_state] = state
    browser_session[:github_oauth_verifier] = verifier
    browser_session[:github_oauth_started_at] = Time.current.to_i
    browser_session[:github_oauth_generation] = SessionRevocation.current.generation
    browser_session[:github_oauth_configuration_id] = record.id
    browser_session[:github_oauth_credential_revision] = record.credential_revision

    query = {
      client_id: record.client_id,
      redirect_uri: "#{hub_origin}/auth/github/callback",
      state:,
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
      code_challenge_method: "S256"
    }
    "#{github_url}/login/oauth/authorize?#{query.to_query}"
  end

  # Exchanges a fresh callback and admits repository readers or enrolled operators.
  def authenticate!(browser_session, code:, state:)
    generation = browser_session[:github_oauth_generation]
    snapshot = credential_snapshot!(browser_session)
    enrollment_proof = browser_session.delete(:hub_admin_enrollment_proof)
    profile = verified_profile!(browser_session, code:, state:)
    if enrollment_proof
      return SessionRevocation.with_generation!(generation) do
        GithubAppConfiguration.with_credentials!(**snapshot) do
          HubAdminEnrollment.consume!(proof: enrollment_proof, state:, profile:)
        end
      end
    end

    if User.find_by(github_id: profile.fetch("id"))&.hub_admin?
      return SessionRevocation.with_generation!(generation) do
        GithubAppConfiguration.with_credentials!(**snapshot) do
          User.admit!(profile, accessible_repository_ids: [])
        end
      end
    end

    record.repositories.synchronize!

    github_id = profile.fetch("id").to_i
    login = profile.fetch("login")
    raise User::AdmissionDenied, "GitHub returned an invalid user identity" if !github_id.positive? || login.blank?

    candidate = User.new(github_id:, login:)
    accessible_ids = Repository.active.filter_map do |repository|
      repository.github_id if repository.authorization.authorized?(
        candidate, fresh: true, configuration: record
      )
    rescue GithubClient::Error
      nil
    end
    SessionRevocation.with_generation!(generation) do
      GithubAppConfiguration.with_credentials!(**snapshot) do
        User.admit!(profile, accessible_repository_ids: accessible_ids)
      end
    end
  rescue KeyError, TypeError
    raise User::AdmissionDenied, "GitHub returned an incomplete user identity"
  ensure
    discard!(browser_session)
  end

  # Proves identity for an existing credential without changing admission or App grants.
  def verified_profile!(browser_session, code:, state:)
    generation = browser_session[:github_oauth_generation]
    snapshot = credential_snapshot!(browser_session)
    verifier = verify_state!(browser_session, state)
    discard!(browser_session)
    token = exchange_code(code, verifier)
    SessionRevocation.with_generation!(generation) do
      GithubAppConfiguration.with_credentials!(**snapshot) { }
    end
    profile = record.github_client.oauth.user(token:)
    SessionRevocation.with_generation!(generation) do
      GithubAppConfiguration.with_credentials!(**snapshot) { profile }
    end
  ensure
    discard!(browser_session)
  end

  # Ends failed or cancelled checks before a callback can fall through to ordinary login.
  def discard!(browser_session)
    clear_state!(browser_session)
  end

  # Captures the starting App identity before one-use state or network work consumes it.
  def credential_snapshot!(browser_session)
    snapshot = {
      configuration_id: browser_session[:github_oauth_configuration_id],
      credential_revision: browser_session[:github_oauth_credential_revision]
    }
    raise InvalidState, "GitHub App credentials changed; start again" if snapshot != record.credential_snapshot

    GithubAppConfiguration.with_credentials!(**snapshot) { }
    snapshot
  end

  private

  # Exchanges one fresh OAuth callback code for a temporary user token.
  def exchange_code(code, verifier)
    record.github_client.oauth.exchange_code \
      client_id: record.client_id,
      client_secret: record.client_secret,
      code:,
      redirect_uri: "#{hub_origin}/auth/github/callback",
      verifier:
  end

  # Confirms GitHub returned the same fresh state Hub created.
  def verify_state!(browser_session, submitted)
    expected = browser_session[:github_oauth_state].to_s
    started_at = browser_session[:github_oauth_started_at]
    fresh = started_at.present? && Time.current.to_i - started_at.to_i <= MAXIMUM_AGE
    matches = expected.present? && expected.bytesize == submitted.to_s.bytesize &&
      ActiveSupport::SecurityUtils.secure_compare(expected, submitted.to_s)
    verifier = browser_session[:github_oauth_verifier]
    raise InvalidState, "Invalid or expired OAuth state" if !fresh || !matches || verifier.blank?
    generation = browser_session[:github_oauth_generation]
    raise SessionRevocation::Superseded if !generation.is_a?(Integer) ||
      generation != SessionRevocation.current.generation
    credential_snapshot!(browser_session)

    verifier
  end

  # Removes OAuth state before any network request so it cannot be replayed.
  def clear_state!(browser_session)
    browser_session.delete(:github_oauth_state)
    browser_session.delete(:github_oauth_verifier)
    browser_session.delete(:github_oauth_started_at)
    browser_session.delete(:github_oauth_generation)
    browser_session.delete(:github_oauth_configuration_id)
    browser_session.delete(:github_oauth_credential_revision)
  end

  # Returns the trusted public Hub origin used in the App configuration.
  def hub_origin = Rails.configuration.x.hub_origin.delete_suffix("/")

  # Returns the configured base URL for GitHub browser pages.
  def github_url = Rails.configuration.x.github_url.delete_suffix("/")
end
