# Reports setup health while keeping stored credentials private.
class GithubAppConfiguration::Diagnostics < ActiveRecord::AssociatedObject
  Result = Data.define(:configuration, :app, :installation)

  # Checks that Hub can authenticate as the configured App and installation.
  def call
    app = record.github_client.apps.get(token: record.tokens.app)
    verify_app!(app)
    remote_installation = if record.installation_id
      record.github_client.installations.get \
        record.installation_id,
        token: record.tokens.app
    end
    Result.new(configuration: "configured", app: "reachable", installation: installation_status(remote_installation))
  end

  private

  # Confirms GitHub returned the App and owner that Hub expects.
  def verify_app!(app)
    owner = app.fetch("owner")
    valid = app.fetch("id").to_i == record.github_app_id &&
      owner.fetch("id").to_i == record.owner_github_id && owner.fetch("type") == record.owner_type
    raise GithubClient::InvalidResponse, "GitHub App identity does not match" if !valid
  rescue KeyError, TypeError, ArgumentError
    raise GithubClient::InvalidResponse, "GitHub returned incomplete App identity"
  end

  # Describes whether the configured installation is available through GitHub.
  def installation_status(payload)
    return "not installed" if payload.nil?

    account = payload.fetch("account")
    return "owner mismatch" if account.fetch("id").to_i != record.owner_github_id

    payload["suspended_at"].present? ? "suspended" : "reachable"
  rescue KeyError, TypeError, ArgumentError
    "invalid response"
  end
end
