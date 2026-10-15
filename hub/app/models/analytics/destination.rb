# == Schema Information
#
# Table name: analytics_destinations
# Database name: primary
#
#  id                :integer          not null, primary key
#  credentials       :text             not null
#  custom_config     :text
#  enabled           :boolean          default(TRUE), not null
#  event_types       :json             not null
#  last_delivered_at :datetime
#  name              :string
#  provider          :string           not null
#  region            :string           not null
#  revision          :integer          default(1), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  repository_id     :integer          not null
#
# Indexes
#
#  index_analytics_destinations_on_builtin_provider      (repository_id,provider) UNIQUE WHERE provider != 'custom'
#  index_analytics_destinations_on_custom_name           (repository_id, lower(name)) UNIQUE WHERE provider = 'custom'
#  index_analytics_destinations_on_id_and_repository_id  (id,repository_id) UNIQUE
#  index_analytics_destinations_on_repository_id         (repository_id)
#
# Foreign Keys
#
#  repository_id  (repository_id => repositories.id)
#
# Check Constraints
#
#  analytics_destination_provider  (provider IN ('segment', 'mixpanel', 'custom'))
#  analytics_destination_region    ((provider = 'segment' AND region IN ('us', 'eu')) OR (provider = 'mixpanel' AND region IN ('us', 'eu', 'in')) OR (provider = 'custom' AND region = 'custom'))
#  analytics_destination_revision  (revision > 0)
#
# Stores one repository's encrypted provider or custom HTTP configuration.
class Analytics::Destination < ApplicationRecord
  after_create :audit_creation
  after_update :audit_change
  after_destroy :audit_deletion
  REGIONS = { "segment" => %w[us eu], "mixpanel" => %w[us eu in], "custom" => %w[custom] }.freeze
  CREDENTIAL_KEYS = {
    "segment" => %w[write_key],
    "mixpanel" => %w[service_account_username service_account_secret project_id]
  }.freeze

  belongs_to :repository
  has_many :deliveries, dependent: :delete_all
  encrypts :credentials, :custom_config
  serialize :credentials, coder: JSON
  serialize :custom_config, coder: JSON

  validates :provider, inclusion: { in: REGIONS.keys }
  validates :provider, uniqueness: { scope: :repository_id }, if: -> { provider != "custom" }
  validates :name, presence: true, length: { maximum: 64 },
    uniqueness: { scope: :repository_id, case_sensitive: false }, if: -> { provider == "custom" }
  validates :name, format: { with: /\A[[:print:]]+\z/ }, allow_blank: true,
    if: -> { provider == "custom" }
  validate :configuration_is_valid
  validate :identity_is_unchanged, on: :update

  # Serializes onboarding and revision changes against new facts and worker claims.
  def configure!(attributes, include_retained: false, keep_pending: false)
    repository.with_lock do
      lock! if persisted?
      if (attributes[:provider] || provider) == "custom"
        configure_custom!(attributes, keep_pending:)
      else
        replacements = attributes.fetch(:credentials, {}).stringify_keys.reject { |_key, value| value.blank? }
        assign_attributes(attributes.except(:credentials))
        self.credentials = (credentials || {}).merge(replacements)
      end
      save!
      deliveries.where(state: %w[pending retryable delivering]).joins(:event)
        .where.not(analytics_events: { name: event_types }).update_all(state: "canceled", lease_token: nil)
      if include_retained
        repository.analytics_events.retained.where(name: event_types).find_each { queue_event!(_1) }
      end
    end
  end

  # Persists one selected fact per destination; paused destinations wait for resume.
  def queue_event!(event)
    raise ArgumentError, "Event belongs to another repository" if event.repository_id != repository_id
    return if event_types.exclude?(event.name)

    deliveries.find_or_create_by!(event:) do |delivery|
      delivery.repository = repository
      delivery.due_at = Time.current
      delivery.destination_revision = revision
    end
  end

  # Exposes the editable shape without decrypting saved header or secret values into page data.
  def public_custom_config
    Analytics::CustomConfiguration.new(custom_config, credentials).public_settings
  end

  private

  # Keeps credentials and destination configuration out of the security log.
  def audit_creation
    record_audit("create")
  end

  # Distinguishes an explicit pause or resume from a configuration edit.
  def audit_change
    return if (saved_changes.keys - %w[updated_at last_delivered_at]).empty?

    operation = if saved_change_to_enabled? && (saved_changes.keys - %w[enabled updated_at]).empty?
      enabled? ? "resume" : "pause"
    else
      "update"
    end
    record_audit(operation)
  end

  # Retains the disconnected destination's identity without its secrets.
  def audit_deletion
    record_audit("delete")
  end

  # Writes in the same primary-database transaction as the settings change.
  def record_audit(operation)
    SecurityAuditEvent.record! \
      action: "analytics_destination.#{operation}", outcome: "succeeded", repository:,
      context: (Current.security_audit_context || {}).merge(analytics_destination_id: id)
  end

  # Old queued work never acquires a new recipient by observing updated settings.
  def configure_custom!(attributes, keep_pending:)
    input = attributes.fetch(:custom_input)
    previous = Analytics::CustomConfiguration.new(custom_config, credentials) if persisted?
    proposed = Analytics::CustomConfiguration.from_input! \
      input, previous:, existing_secrets: credentials || {}
    original = custom_config
    original_secrets = credentials
    settings = attributes.except(:custom_input, :credentials, :region).merge(region: "custom")
    settings[:name] = settings[:name].strip if settings[:name].is_a?(String)
    assign_attributes(settings)
    self.custom_config = proposed.config
    self.credentials = proposed.secrets
    return if !persisted? || (original == custom_config && original_secrets == credentials)

    auth_only = auth_only_change?(original, original_secrets, proposed)
    if keep_pending && !auth_only
      raise Analytics::CustomConfiguration::Invalid,
        "Pending events can be kept only for authentication-only changes"
    end

    self.revision += 1
    self.last_delivered_at = nil
    active = deliveries.where(state: %w[pending retryable delivering])
    if keep_pending
      active.where(state: %w[pending retryable]).update_all(destination_revision: revision)
      active.where(state: "delivering").update_all \
        state: "canceled", lease_token: nil, enqueue_claim_expires_at: nil
    else
      active.update_all(state: "canceled", lease_token: nil, enqueue_claim_expires_at: nil)
    end
  end

  # A body, URL, response rule, or non-auth header change is not a credential rotation.
  def auth_only_change?(original, original_secrets, proposed)
    old_headers = original.fetch("headers")
    new_headers = proposed.config.fetch("headers")
    changed_headers = (old_headers.keys | new_headers.keys).select { old_headers[_1] != new_headers[_1] }
    original.except("headers") == proposed.config.except("headers") &&
      changed_headers.all? { Analytics::CustomConfiguration::AUTHENTICATION_HEADERS.include?(_1.downcase) } &&
      old_headers.keys.sort == new_headers.keys.sort &&
      (original_secrets != proposed.secrets || changed_headers.any?)
  end

  # Requires fixed regions, explicit event selection, and complete provider credentials.
  def configuration_is_valid
    errors.add(:region, "is not supported") if !REGIONS.fetch(provider, []).include?(region)
    valid_types = event_types.is_a?(Array) && event_types.any? &&
      (event_types - Analytics::Event::TYPES).empty? && event_types.uniq == event_types
    errors.add(:event_types, "must select known events") if !valid_types
    if provider == "custom"
      return if persisted? && changes_to_save.keys == [ "enabled" ]

      begin
        Analytics::CustomConfiguration.new(custom_config, credentials).validate!
      rescue Analytics::CustomConfiguration::Invalid, Analytics::CustomEndpoint::Invalid => error
        errors.add(:custom_config, error.message)
      end
    else
      keys = CREDENTIAL_KEYS.fetch(provider, [])
      valid_credentials = credentials.is_a?(Hash) && credentials.keys.sort == keys.sort &&
        keys.all? { credentials[_1].is_a?(String) && credentials[_1].present? && credentials[_1].bytesize <= 1024 }
      if provider == "mixpanel" && valid_credentials
        valid_credentials = credentials["project_id"].match?(/\A[1-9]\d*\z/) &&
          !credentials["service_account_username"].include?(":")
      end
      errors.add(:credentials, "must supply the required provider credentials") if !valid_credentials
    end
  end

  # Changing a provider requires explicit disconnect and onboarding.
  def identity_is_unchanged
    %i[repository_id provider].each do |attribute|
      errors.add(attribute, "cannot change") if will_save_change_to_attribute?(attribute)
    end
  end
end
