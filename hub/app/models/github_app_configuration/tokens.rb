# Creates the short-lived tokens used for GitHub App requests.
class GithubAppConfiguration::Tokens < ActiveRecord::AssociatedObject
  # Creates a short-lived token that authenticates as the GitHub App.
  def app
    now = Time.current.to_i
    JWT.encode({ iat: now - 60, exp: now + 9.minutes.to_i, iss: record.client_id },
      OpenSSL::PKey::RSA.new(record.private_key), "RS256")
  rescue OpenSSL::PKey::RSAError => error
    raise GithubClient::InvalidResponse, "The stored GitHub App private key is invalid: #{error.message}"
  end

  # Creates and briefly reuses one installation access token.
  def installation
    raise GithubClient::InvalidResponse, "The GitHub App installation is not active" if record.installation_state != "active"

    for_installation(record.installation_id)
  end

  # Fetches a token for an owner-verified installation before its state is saved.
  def for_installation(installation_id)
    if !installation_id.is_a?(Integer) || !installation_id.positive?
      raise GithubClient::InvalidResponse, "GitHub returned an invalid installation"
    end

    if @installation_id == installation_id && @installation_token &&
        @installation_token_expires_at > 1.minute.from_now
      return @installation_token
    end

    payload = record.github_client.installations.create_token \
      installation_id,
      token: app
    raise KeyError if !payload.is_a?(Hash)

    token = payload.fetch("token")
    expires_at = Time.iso8601(payload.fetch("expires_at"))
    raise KeyError if !token.is_a?(String) || token.blank? || expires_at <= Time.current

    @installation_token = token
    @installation_token_expires_at = expires_at
    @installation_id = installation_id
    @installation_token
  rescue KeyError, TypeError, ArgumentError
    raise GithubClient::InvalidResponse, "GitHub returned an incomplete installation token"
  end
end
