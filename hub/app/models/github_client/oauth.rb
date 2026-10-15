# Calls GitHub OAuth APIs for token exchange and user identity.
class GithubClient::Oauth
  # Uses GitHub's API and browser-facing OAuth transports.
  def initialize(api_transport:, oauth_transport:)
    @api_transport = api_transport
    @oauth_transport = oauth_transport
  end

  # Exchanges one OAuth callback code for a temporary user token.
  def exchange_code(client_id:, client_secret:, code:, redirect_uri:, verifier:)
    payload = oauth_transport.request \
      :post,
      "/login/oauth/access_token",
      body: {
        client_id:,
        client_secret:,
        code:,
        redirect_uri:,
        code_verifier: verifier
      },
      accept: "application/json"
    raise KeyError if !payload.is_a?(Hash)

    if payload["error"].in?(%w[bad_verification_code access_denied])
      raise GithubClient::Forbidden, "GitHub rejected OAuth authorization"
    end
    token = payload.fetch("access_token")
    raise KeyError if !token.is_a?(String) || token.blank?

    token
  rescue KeyError, TypeError
    raise GithubClient::InvalidResponse, "GitHub returned an incomplete OAuth token"
  end

  # Fetches the stable GitHub profile for one temporary OAuth token.
  def user(token:)
    profile = api_transport.request(:get, "/user", token:)
    raise GithubClient::InvalidResponse, "GitHub returned an invalid user profile" if !profile.is_a?(Hash)

    profile
  end

  private

  attr_reader :api_transport, :oauth_transport
end
