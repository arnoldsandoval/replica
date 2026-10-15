# == Schema Information
#
# Table name: webhook_deliveries
# Database name: primary
#
#  id                    :integer          not null, primary key
#  event                 :string           not null
#  payload_sha256        :string           not null
#  processed_at          :datetime
#  processing_started_at :datetime
#  processing_token      :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  build_id              :integer
#  github_delivery_id    :string           not null
#
# Indexes
#
#  index_webhook_deliveries_on_build_id            (build_id)
#  index_webhook_deliveries_on_created_at          (created_at)
#  index_webhook_deliveries_on_github_delivery_id  (github_delivery_id) UNIQUE
#
# Foreign Keys
#
#  build_id  (build_id => builds.id) ON DELETE => nullify
#
# Check Constraints
#
#  webhook_deliveries_event             (length(trim(event)) BETWEEN 1 AND 100)
#  webhook_deliveries_github_id         (length(trim(github_delivery_id)) BETWEEN 1 AND 255)
#  webhook_deliveries_payload_sha256    (length(payload_sha256) = 64 AND payload_sha256 NOT GLOB '*[^0-9a-f]*')
#  webhook_deliveries_processing_state  (processed_at IS NULL OR processing_started_at IS NULL)
#
class WebhookDelivery < ApplicationRecord
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  PROCESSING_TIMEOUT = 5.minutes

  belongs_to :build, optional: true

  validates :github_delivery_id, presence: true, length: { maximum: 255 }, uniqueness: true
  validates :event, presence: true, length: { maximum: 100 }
  validates :payload_sha256, format: { with: SHA256_FORMAT }
  validate :identity_is_unchanged, on: :update

  # Reports whether this delivery already completed successfully.
  def processed? = processed_at.present?

  # Confirms a repeated delivery has the same authenticated contents.
  def matches?(event:, payload_sha256:)
    self.event == event && self.payload_sha256 == payload_sha256
  end

  # Marks an unfinished or abandoned delivery as being processed by this request.
  def start_processing!
    token = SecureRandom.uuid
    claimed = self.class.where(id:, processed_at: nil)
      .where(processing_started_at: [ nil, ...PROCESSING_TIMEOUT.ago ])
      .update_all(processing_started_at: Time.current, processing_token: token) == 1
    @processing_token = token if claimed
    claimed
  end

  # Only the current request may complete a reclaimed processing lease.
  def finish_processing!(build:)
    return false if @processing_token.nil?

    self.class.where(id:, processed_at: nil, processing_token: @processing_token)
      .update_all(build_id: build&.id, processed_at: Time.current,
        processing_started_at: nil, processing_token: nil, updated_at: Time.current) == 1
  end

  # Clears the processing time so GitHub can retry a failed delivery immediately.
  def allow_retry!
    return if @processing_token.nil?

    self.class.where(id:, processed_at: nil, processing_token: @processing_token)
      .update_all(processing_started_at: nil, processing_token: nil)
  end

  private

  # Prevents a delivery ID from being reused for different webhook contents.
  def identity_is_unchanged
    %i[github_delivery_id event payload_sha256].each do |attribute|
      errors.add(attribute, "cannot change") if public_send("will_save_change_to_#{attribute}?")
    end
  end
end
