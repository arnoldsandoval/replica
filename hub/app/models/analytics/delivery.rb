# == Schema Information
#
# Table name: analytics_deliveries
# Database name: primary
#
#  id                       :integer          not null, primary key
#  attempts                 :integer          default(0), not null
#  delivered_at             :datetime
#  destination_revision     :integer          default(1), not null
#  due_at                   :datetime         not null
#  enqueue_claim_expires_at :datetime
#  failure_code             :string
#  lease_token              :string
#  state                    :string           default("pending"), not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  destination_id           :bigint           not null
#  event_id                 :bigint           not null
#  repository_id            :integer          not null
#
# Indexes
#
#  index_analytics_deliveries_on_event_id_and_destination_id  (event_id,destination_id) UNIQUE
#  index_analytics_deliveries_on_repository_id                (repository_id)
#  index_analytics_deliveries_on_state_and_due_at             (state,due_at)
#
# Foreign Keys
#
#  [destination_id, repository_id]  ([destination_id, repository_id] => analytics_destinations[id, repository_id]) ON DELETE => cascade
#  [event_id, repository_id]        ([event_id, repository_id] => analytics_events[id, repository_id]) ON DELETE => cascade
#  repository_id                    (repository_id => repositories.id)
#
# Check Constraints
#
#  analytics_delivery_attempts              (attempts >= 0)
#  analytics_delivery_destination_revision  (destination_revision > 0)
#  analytics_delivery_state                 (state IN ('pending', 'delivering', 'retryable', 'succeeded', 'failed', 'canceled'))
#
# Recovers cross-database queue gaps and bounds at-least-once delivery attempts.
class Analytics::Delivery < ApplicationRecord
  MAXIMUM_ATTEMPTS = 8
  LEASE = 5.minutes
  ENQUEUE_CLAIM = 15.minutes
  DUE_STATES = %w[pending retryable delivering].freeze

  belongs_to :repository
  belongs_to :event
  belongs_to :destination
  after_create_commit :enqueue

  performs :deliver!, queue_as: :default do
    self.enqueue_after_transaction_commit = true
    discard_on ActiveJob::DeserializationError
  end

  # Enqueues persisted due work, including abandoned leases after a worker crash.
  def self.recover!
    due.find_each(&:enqueue)
  end

  # Restricts recovery to installed repositories and enabled destinations.
  def self.due
    joins(:destination, :repository, :event)
      .where(state: DUE_STATES, due_at: ..Time.current)
      .where(analytics_destinations: { enabled: true }, repositories: { installation_state: "active" })
      .where(analytics_events: { occurred_at: 90.days.ago.. })
      .where("analytics_deliveries.destination_revision = analytics_destinations.revision")
      .where("analytics_deliveries.enqueue_claim_expires_at IS NULL OR " \
        "analytics_deliveries.enqueue_claim_expires_at <= ?", Time.current)
  end

  # Queue failure leaves the durable outbox available for scheduled recovery.
  def enqueue
    claim_expires_at = ENQUEUE_CLAIM.from_now
    claimed = self.class.due.where(id:).update_all(enqueue_claim_expires_at: claim_expires_at)
    return if claimed.zero?

    job = deliver_later!
    Rails.logger.error("Analytics delivery #{id} enqueue was rejected") if !job
  rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => error
    Rails.logger.error("Analytics delivery #{id} enqueue failed: #{error.class}")
  ensure
    if claimed&.positive? && !job
      self.class.where(id:, enqueue_claim_expires_at: claim_expires_at)
        .update_all(enqueue_claim_expires_at: nil)
    end
  end

  # Claims briefly in the database, then sends without holding a transaction.
  def deliver!
    token = SecureRandom.uuid
    with_lock do
      update!(enqueue_claim_expires_at: nil) if enqueue_claim_expires_at
      return if !DUE_STATES.include?(state) || due_at > Time.current
      return if !sendable?
      if attempts >= MAXIMUM_ATTEMPTS
        update!(state: "failed", failure_code: "attempts_exhausted", lease_token: nil)
        return
      end

      update!(state: "delivering", attempts: attempts + 1, due_at: LEASE.from_now, lease_token: token)
    end
    return if !sendable?

    Analytics::Transport.new(destination).deliver(event)
    finish!(token, state: "succeeded", failure_code: nil, delivered_at: Time.current)
  rescue Analytics::Transport::Failure => error
    retryable = error.retryable && attempts < MAXIMUM_ATTEMPTS
    finish! \
      token,
      state: retryable ? "retryable" : "failed",
      failure_code: error.code,
      due_at: [ 30.seconds * (2**(attempts - 1)), 6.hours ].min.from_now
  end

  private

  # Rechecks revocation and selection immediately before outbound work.
  def sendable?
    destination.reload.enabled? && destination.revision == destination_revision &&
      repository.reload.installation_state == "active" &&
      event.occurred_at >= 90.days.ago && destination.event_types.include?(event.name)
  end

  # A stale worker cannot overwrite a newer attempt or a disconnected destination.
  def finish!(token, **attributes)
    transaction do
      changed = self.class.where(id:, lease_token: token, state: "delivering")
        .update_all(**attributes, lease_token: nil, updated_at: Time.current)
      if changed.positive? && attributes[:state] == "succeeded"
        Analytics::Destination.where(id: destination_id).update_all(last_delivered_at: attributes[:delivered_at])
      end
    end
  end
end
