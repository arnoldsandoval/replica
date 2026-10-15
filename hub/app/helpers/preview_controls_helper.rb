module PreviewControlsHelper
  # Separates local saved values by viewer, access mode and prototype without exposing private identity.
  def preview_controls_identity(prototype, context:)
    identity = [ context, prototype.repository_id, prototype.id, prototype.branch_name ].to_json
    key = Rails.application.key_generator.generate_key("replica-build-controls-storage-v1", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, identity)
  end
end
