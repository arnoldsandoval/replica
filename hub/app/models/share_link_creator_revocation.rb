# == Schema Information
#
# Table name: share_link_creator_revocations
# Database name: primary
#
#  id            :integer          not null, primary key
#  revision      :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  repository_id :integer          not null
#  user_id       :integer          not null
#
# Indexes
#
#  idx_on_repository_id_user_id_5f43486b67                (repository_id,user_id) UNIQUE
#  index_share_link_creator_revocations_on_repository_id  (repository_id)
#  index_share_link_creator_revocations_on_user_id        (user_id)
#
# Foreign Keys
#
#  repository_id  (repository_id => repositories.id)
#  user_id        (user_id => users.id)
#
# Check Constraints
#
#  share_link_creator_revocations_revision  (revision >= 0)
#
# Invalidates earlier GitHub permission results without retaining user tokens.
class ShareLinkCreatorRevocation < ApplicationRecord
  belongs_to :repository
  belongs_to :user

  Proof = Data.define(:repository_id, :user_id, :revision)
  class Changed < StandardError; end

  class << self
    # Captures the revocation boundary before an external permission lookup.
    def proof_for(repository, user)
      revision = where(repository:, user:).pick(:revision) || 0
      Proof.new(repository_id: repository.id, user_id: user.id, revision:)
    end

    # Must run inside creation's SQLite write transaction.
    def verify!(proof, repository:, user:)
      if proof.repository_id != repository.id || proof.user_id != user.id ||
          proof != proof_for(repository, user)
        raise Changed
      end
    end

    # Revokes only this creator's links and invalidates earlier positive checks.
    def confirm_loss!(repository:, user:)
      transaction do
        state = find_or_create_by!(repository:, user:)
        state.increment!(:revision)
        links = ShareLink.where(created_by: user, prototype: repository.prototypes, revoked_at: nil)
        ShareLink.revoke_all!(links, actor: user)
        SecurityAuditEvent.record! \
          action: "share_link.creator_access_loss",
          outcome: "succeeded",
          repository:,
          actor: user,
          context: (Current.security_audit_context || {}).merge(target_user_id: user.id)
      end
    end
  end
end
