# Keeps provider-neutral records separate from product and provider namespaces.
module Analytics
  # Uses conventional names for the analytics model namespace.
  def self.table_name_prefix
    "analytics_"
  end

  # Correlates authored actions across this Hub without exporting GitHub identities.
  def self.actor_id(user: nil, github_id: nil)
    identity = github_id || user&.github_id
    identity = identity ? "github/#{identity}" : ("local/#{user.id}" if user)
    return if identity.nil?

    key = Rails.application.key_generator.generate_key("replica/analytics/actors", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, identity)
  end
end
