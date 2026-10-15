# == Schema Information
#
# Table name: preview_grants
# Database name: primary
#
#  id           :integer          not null, primary key
#  expires_at   :datetime         not null
#  return_path  :string(2048)     not null
#  token_digest :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  build_id     :integer          not null
#  session_id   :integer          not null
#
# Indexes
#
#  index_preview_grants_on_build_id      (build_id)
#  index_preview_grants_on_session_id    (session_id)
#  index_preview_grants_on_token_digest  (token_digest) UNIQUE
#
# Foreign Keys
#
#  build_id    (build_id => builds.id) ON DELETE => cascade
#  session_id  (session_id => sessions.id) ON DELETE => cascade
#
# Check Constraints
#
#  preview_grants_return_path   (length(CAST(return_path AS BLOB)) BETWEEN 1 AND 2048 AND substr(return_path, 1, 1) = '/')
#  preview_grants_token_digest  (length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*')
#
# Gives one browser a short-lived, one-use handoff to a Build preview host.
class PreviewGrant < ApplicationRecord
  MAXIMUM_RETURN_PATH_BYTES = 2_048
  TOKEN_FORMAT = /\A[0-9a-f]{64}\z/

  belongs_to :build
  belongs_to :session

  validates :token_digest, format: { with: TOKEN_FORMAT }, uniqueness: true
  validates :return_path, length: { in: 1..MAXIMUM_RETURN_PATH_BYTES },
    format: { with: %r{\A/(?!/)[^[:cntrl:][:space:]\\]*\z} }
  validates :expires_at, presence: true

  class << self
    # Creates a handoff only for a browser Session that still exists.
    def issue!(build:, session:, return_path:)
      token = SecureRandom.urlsafe_base64(32)
      transaction do
        live_session = Session.uncached { Session.find(session.id) }
        create! \
          build:,
          session: live_session,
          token_digest: Digest::SHA256.hexdigest(token),
          return_path: validate_return_path(return_path),
          expires_at: 2.minutes.from_now
      end
      token
    end

    # Returns one fresh grant for the Build named by the preview host.
    def find_valid(token, build_id:)
      return if !token.is_a?(String) || token.bytesize > 128

      grant = includes(:build, session: :user).find_by(token_digest: Digest::SHA256.hexdigest(token))
      return if grant.nil? || grant.build_id != build_id || grant.expires_at <= Time.current

      grant
    end

    # Consumes a fresh grant once after repository authorization succeeds.
    def consume(grant)
      transaction do
        return false if !Session.where(id: grant.session_id).exists?

        where(id: grant.id).where("expires_at > ?", Time.current).delete_all == 1
      end
    end

    # Removes expired grants that can no longer authorize a preview.
    def clear_expired!
      where(expires_at: ..Time.current).delete_all
    end

    # Returns a local preview path that is safe to use in a redirect.
    def validate_return_path(value)
      valid = value.is_a?(String) && value.valid_encoding? && value.match?(%r{\A/(?!/)})
      valid &&= value.bytesize <= MAXIMUM_RETURN_PATH_BYTES && !value.match?(/[[:cntrl:][:space:]\\]/)
      if !valid
        raise \
          ArgumentError,
          "Preview return path must be a local path without backslashes, control characters, or whitespace. " \
            "It must contain at most 2,048 bytes."
      end

      value
    end
  end
end
