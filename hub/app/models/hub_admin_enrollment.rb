# == Schema Information
#
# Table name: hub_admin_enrollments
# Database name: primary
#
#  id                 :integer          not null, primary key
#  consumed_at        :datetime
#  expires_at         :datetime         not null
#  oauth_state_digest :string
#  proof_digest       :string           not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_hub_admin_enrollments_on_expires_at    (expires_at)
#  index_hub_admin_enrollments_on_proof_digest  (proof_digest) UNIQUE
#
# Binds operator-secret possession to one verified GitHub callback in the same browser.
class HubAdminEnrollment < ApplicationRecord
  LIFETIME = 15.minutes
  PROOF_PATTERN = /\A[A-Za-z0-9_-]{43}\z/

  class InvalidProof < StandardError; end

  # Creates a digest-only proof without requiring App reset on configured deployments.
  def self.start!(submitted_secret, bootstrap_secret: ENV.fetch("REPLICA_BOOTSTRAP_SECRET", ""))
    expected = Digest::SHA256.hexdigest(bootstrap_secret.to_s)
    submitted = Digest::SHA256.hexdigest(submitted_secret.to_s)
    if bootstrap_secret.blank? || !ActiveSupport::SecurityUtils.secure_compare(expected, submitted)
      raise InvalidProof, "Operator authorization failed"
    end

    proof = SecureRandom.urlsafe_base64(32)
    enrollment = create!(proof_digest: Digest::SHA256.hexdigest(proof), expires_at: LIFETIME.from_now)
    [ enrollment, proof ]
  end

  # Restricts the proof to the OAuth state created immediately after secret verification.
  def bind_oauth!(state)
    update!(oauth_state_digest: Digest::SHA256.hexdigest(state))
  end

  # Grants only the identity GitHub just verified and consumes the proof atomically.
  def self.consume!(proof:, state:, profile:)
    raise InvalidProof, "Operator authorization failed" if !proof.is_a?(String) || !proof.match?(PROOF_PATTERN)

    enrollment = find_by(proof_digest: Digest::SHA256.hexdigest(proof))
    raise InvalidProof, "Operator authorization failed" if enrollment.nil?

    enrollment.with_lock do
      expected_state = Digest::SHA256.hexdigest(state.to_s)
      matches = enrollment.oauth_state_digest.present? &&
        ActiveSupport::SecurityUtils.secure_compare(enrollment.oauth_state_digest, expected_state)
      if enrollment.consumed_at || enrollment.expires_at <= Time.current || !matches
        raise InvalidProof, "Operator authorization failed"
      end

      user = User.save_github_identity!(profile)
      user.update!(hub_admin: true)
      enrollment.update!(consumed_at: Time.current)
      SecurityAuditEvent.record!(action: "hub_admin.enroll", outcome: "succeeded", actor: user)
      user
    end
  end

  # Removes used and expired proofs independently of the retained audit history.
  def self.clear_expired!
    where(expires_at: ..Time.current).or(where.not(consumed_at: nil)).delete_all
  end
end
