# == Schema Information
#
# Table name: copilot_connections
# Database name: primary
#
#  id            :integer          not null, primary key
#  refused_at    :datetime
#  singleton_key :integer          default(1), not null
#  token_digest  :string           not null
#  verified_at   :datetime         not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :integer          not null
#
# Indexes
#
#  index_copilot_connections_on_singleton_key  (singleton_key) UNIQUE
#  index_copilot_connections_on_user_id        (user_id)
#
# Foreign Keys
#
#  user_id  (user_id => users.id) ON DELETE => cascade
#
# Check Constraints
#
#  copilot_connections_singleton     (singleton_key = 1)
#  copilot_connections_token_digest  (length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*')
#
# Records that a Hub administrator connected Copilot, which turns on Learnings for this Hub, and
# what Copilot last said about the token Hub uses.
#
# Hub keeps no Copilot credential. The operator provides REPLICA_COPILOT_TOKEN, a fine-grained
# personal access token whose only permission is Copilot requests, the way they provide Hub's other
# secrets. Hub passes it only to replica-learning, and Copilot counts the usage toward the token
# owner's plan. The connection keeps the token's SHA-256 digest, so a refusal applies only to the
# token Copilot refused, and a replaced token starts fresh. The connection ends when an
# administrator disconnects it or when the person who connected it stops being a Hub administrator.
class CopilotConnection < ApplicationRecord
  # The Copilot check that connecting starts usually takes about a second.
  CHECK_TIME = 20.seconds

  # Copilot refused the token, or Hub has none, so Hub cannot make Copilot requests.
  class Refused < StandardError; end
  class ChangeDenied < StandardError
    attr_reader :reason

    # Exposes only a fixed policy reason, never a token or Copilot response.
    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  belongs_to :user

  validates :token_digest, :verified_at, presence: true
  validates :singleton_key, inclusion: { in: [ 1 ] }

  class << self
    # The connection Hub uses, when an administrator connected one.
    def current
      find_by(singleton_key: 1)
    end

    # The Copilot token the operator gave Hub in REPLICA_COPILOT_TOKEN, or nil.
    def token
      Rails.configuration.x.copilot_token.presence
    end

    # A token's SHA-256 digest, which tells tokens apart without keeping them.
    def digest(token)
      Digest::SHA256.hexdigest(token)
    end

    # Connects Copilot, or checks it again, for a current Hub administrator with fresh GitHub
    # proof, once Copilot answers with the operator's token. Raises Refused when Copilot rejects the
    # token, and records the refusal on an existing connection. Connecting again clears an earlier
    # refusal and names the administrator who connected. A disconnect or replacement while Copilot
    # answers cancels this check rather than restoring the earlier enablement.
    def connect!(actor:, browser_session:)
      live_actor, = authorized!(actor:, browser_session:)
      token = self.token
      raise ChangeDenied, :no_token if token.nil?

      earlier, generation = uncached do
        transaction { [ current, CopilotConnectionState.current.generation ] }
      end
      begin
        check!(token)
      rescue Refused
        earlier&.refuse!(token:)
        raise
      end
      uncached do
        transaction do
          live_actor, live_session = authorized!(actor: live_actor, browser_session:)
          if current&.id != earlier&.id || CopilotConnectionState.current.generation != generation
            raise ChangeDenied, :connection_changed
          end

          where(singleton_key: 1).delete_all
          connection = create! \
            user: live_actor,
            token_digest: digest(token),
            verified_at: Time.current
          CopilotConnectionState.advance!
          SecurityAuditEvent.record! \
            action: "copilot_connection.connect",
            outcome: "succeeded",
            actor: live_actor,
            context: audit_context(live_session.id)
          connection
        end
      end
    end

    # Disconnects Copilot for a current Hub administrator with fresh GitHub proof. The token stays
    # where the operator keeps it.
    def disconnect!(actor:, browser_session:)
      uncached do
        transaction do
          live_actor, live_session = authorized!(actor:, browser_session:)
          connection = current
          raise ChangeDenied, :not_connected if connection.nil?

          connection.destroy!
          CopilotConnectionState.advance!
          SecurityAuditEvent.record! \
            action: "copilot_connection.disconnect",
            outcome: "succeeded",
            actor: live_actor,
            context: audit_context(live_session.id)
        end
      end
    end

    private

    # Asks Copilot to answer with the token, without labeling anything, or raises Refused.
    def check!(token)
      Learning::Command.new(timeout: CHECK_TIME).call("copilot", "status", copilot_token: token)
    rescue Learning::Error => error
      raise Refused, error.message if error.code == "unauthorized"

      raise
    end

    # The current Hub administrator, and their browser Session with fresh GitHub proof, or an error.
    # Reads bypass the request cache, so another request's committed role or Session change counts.
    def authorized!(actor:, browser_session:)
      uncached do
        live_actor = User.where.not(github_id: nil).find_by(id: actor.id, hub_admin: true)
        raise ChangeDenied, :not_authorized if live_actor.nil?

        live_session = Session.find_by(id: browser_session&.id, user_id: live_actor.id)
        raise ChangeDenied, :not_authorized if live_session.nil?
        raise FreshAuthorization::Invalid if !FreshAuthorization.fresh?(live_session)

        [ live_actor, live_session ]
      end
    end

    # Request context with the browser Session that acted, for the security audit.
    def audit_context(session_id)
      (Current.security_audit_context || {}).merge(session_id:)
    end
  end

  # Whether Hub may make Copilot requests now: it has a token, Copilot has not refused that token,
  # and the person who connected Copilot is still a Hub administrator.
  def usable?
    self.class.token.present? && !refused? && User.where(id: user_id, hub_admin: true).exists?
  end

  # Whether Copilot refused the token Hub has now. A refusal of an earlier token does not count.
  def refused?
    token = self.class.token
    refused_at.present? && token.present? && token_digest == self.class.digest(token)
  end

  # The operator's token for one Copilot request, or Refused when Hub cannot use it. Hub reads the
  # connection again first, so an instance loaded earlier never hands out a token that an
  # administrator has since disconnected or Copilot has since refused.
  def access_token!
    reload
    token = self.class.token
    raise Refused, "Hub has no Copilot token. Set REPLICA_COPILOT_TOKEN and restart Hub." if token.nil?
    raise Refused, "Copilot refused this token on #{refused_at.to_date}." if refused?
    raise Refused, "#{user.login} is no longer a Hub administrator." if !usable?

    token
  rescue ActiveRecord::RecordNotFound
    raise Refused, "An administrator disconnected Copilot."
  end

  # Records that Copilot refused a token, so Hub stops using it until an administrator checks it
  # again or the operator replaces it. Results that this worker can identify as superseded are
  # ignored; token replacement still requires the non-overlapping deployment in docs/copilot.md.
  # Returns whether it recorded a new refusal.
  def refuse!(token: self.class.token)
    with_current_token(token) do |digest|
      next false if refused_at && token_digest == digest

      update!(refused_at: Time.current, token_digest: digest)
      SecurityAuditEvent.record!(action: "copilot_connection.use", outcome: "failed", actor: nil)
      true
    end
  end

  # Records that Copilot answered with a still-current token. A request already in flight cannot
  # clear that token's refusal; only an administrator's explicit recheck can. Returns whether saved.
  def verified!(token: self.class.token)
    with_current_token(token) do |digest|
      next false if refused_at && token_digest == digest

      update!(verified_at: Time.current, refused_at: nil, token_digest: digest)
      true
    end
  end

  private

  # Serializes a result with disconnect and other results. A rotated token may replace the state
  # this request read, but cannot overwrite a different token's intervening result. A digest does
  # not order configurations across processes; rolling token replacement is not supported.
  def with_current_token(token)
    return false if token.blank?

    previous_digest = token_digest_in_database
    transaction do
      reload
      digest = self.class.digest(token)
      next false if self.class.token != token || (token_digest != previous_digest && token_digest != digest)

      yield digest
    end
  rescue ActiveRecord::RecordNotFound
    false
  end
end
