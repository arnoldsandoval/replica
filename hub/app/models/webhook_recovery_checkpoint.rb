# == Schema Information
#
# Table name: webhook_recovery_checkpoints
# Database name: primary
#
#  id                                 :integer          not null, primary key
#  credential_revision                :bigint           default(1), not null
#  cursor                             :string(2048)
#  due_at                             :datetime         not null
#  enqueue_claim_expires_at           :datetime
#  failure_code                       :string
#  failures                           :integer          default(0), not null
#  gap_ended_at                       :datetime
#  gap_started_at                     :datetime
#  last_completed_at                  :datetime
#  last_completed_credential_revision :bigint
#  last_completed_scan_started_at     :datetime
#  lease_token                        :string
#  pages                              :integer          default(0), not null
#  scan_started_at                    :datetime
#  created_at                         :datetime         not null
#  updated_at                         :datetime         not null
#  github_app_configuration_id        :bigint           not null
#  github_app_id                      :bigint           not null
#
# Indexes
#
#  idx_on_github_app_configuration_id_aabbf4a511     (github_app_configuration_id) UNIQUE
#  index_webhook_recovery_checkpoints_on_updated_at  (updated_at)
#
# Check Constraints
#
#  webhook_recovery_app       (github_app_configuration_id > 0 AND github_app_id > 0)
#  webhook_recovery_counters  (pages >= 0 AND failures >= 0)
#  webhook_recovery_revision  (credential_revision > 0)
#
# Makes periodic App recovery durable across queue rejection and worker restarts.
class WebhookRecoveryCheckpoint < ApplicationRecord
  LEASE = 5.minutes
  ENQUEUE_CLAIM = 15.minutes

  has_object :scan

  performs :recover!, queue_as: :default do
    self.enqueue_after_transaction_commit = true
    discard_on ActiveJob::DeserializationError
  end

  class << self
    # Recurring work recovers both missed receipts and missed queue submissions.
    def recover_all!
      return if LocalDevelopment.enabled?

      WebhookRedelivery.expire!
      checkpoint = transaction do
        configuration = GithubAppConfiguration.current
        where.not(github_app_configuration_id: configuration&.id)
          .update_all(failure_code: "app_changed", lease_token: nil, enqueue_claim_expires_at: nil)
        WebhookRedelivery.where(state: WebhookRedelivery::ACTIVE_STATES)
          .where.not(github_app_configuration_id: configuration&.id)
          .update_all(state: "failed", failure_code: "app_changed", lease_token: nil, updated_at: Time.current)
        next if configuration.nil?

        WebhookRedelivery.where(github_app_configuration_id: configuration.id, state: WebhookRedelivery::ACTIVE_STATES)
          .where.not(credential_revision: configuration.credential_revision)
          .update_all(state: "pending", failure_code: "credentials_changed", lease_token: nil, updated_at: Time.current)
        entry = create_or_find_by!(github_app_configuration_id: configuration.id) do |record|
          record.github_app_id = configuration.github_app_id
          record.credential_revision = configuration.credential_revision
          record.due_at = Time.current
        end
        if entry.credential_revision != configuration.credential_revision
          entry.update! \
            credential_revision: configuration.credential_revision,
            cursor: nil, pages: 0, scan_started_at: nil, lease_token: nil,
            enqueue_claim_expires_at: nil, due_at: Time.current
        end
        entry
      end
      checkpoint&.enqueue
    end
  end

  # Queue failure leaves the primary-database checkpoint ready for another tick.
  def enqueue
    claim = ENQUEUE_CLAIM.from_now
    claimed = self.class.where(id:, due_at: ..Time.current)
      .where(enqueue_claim_expires_at: [ nil, ..Time.current ])
      .update_all(enqueue_claim_expires_at: claim)
    return if claimed.zero?

    job = recover_later!
    Rails.logger.error("Webhook recovery #{id} enqueue was rejected") if !job
  rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => error
    Rails.logger.error("Webhook recovery #{id} enqueue failed: #{error.class}")
  ensure
    if claimed&.positive? && !job
      self.class.where(id:, enqueue_claim_expires_at: claim).update_all(enqueue_claim_expires_at: nil)
    end
  end

  # Only one worker owns the saved cursor, and no GitHub I/O holds its lock.
  def recover!
    token = SecureRandom.uuid
    with_lock do
      update!(enqueue_claim_expires_at: nil) if enqueue_claim_expires_at
      return if due_at > Time.current

      update!(lease_token: token, due_at: LEASE.from_now)
    end
    scan.call(token:)
  end

  # Renews ownership before bounded I/O so another worker cannot share the cursor.
  def renew!(token)
    with_current_credentials(token) do
      self.class.where(id:, credential_revision:, lease_token: token).update_all(due_at: LEASE.from_now) == 1
    end
  end

  # A stale worker cannot move or reset a newer scan's checkpoint.
  def finish!(token, **attributes)
    with_current_credentials(token) do
      self.class.where(id:, credential_revision:, lease_token: token).update_all(**attributes, updated_at: Time.current) == 1
    end
  end

  private

  # A revision change can record a denial, never advance an old scan.
  def with_current_credentials(token)
    GithubAppConfiguration.with_credentials! \
      configuration_id: github_app_configuration_id, credential_revision: do
        yield
      end
  rescue GithubAppConfiguration::Superseded
    self.class.transaction do
      current = GithubAppConfiguration.current
      same_app = current && current.id == github_app_configuration_id && current.github_app_id == github_app_id
      self.class.where(id:, credential_revision:, lease_token: token)
        .update_all \
          failure_code: same_app ? "credentials_changed" : "app_changed",
          lease_token: nil, enqueue_claim_expires_at: nil, updated_at: Time.current
    end
    false
  end
end
