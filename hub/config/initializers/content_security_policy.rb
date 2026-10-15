require Rails.root.join("lib/hub_content_security_policy")

Rails.application.configure do
  config.content_security_policy do |policy|
    HubContentSecurityPolicy.build(policy:, development: Rails.env.development?)
  end
  config.content_security_policy_report_only = false
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(32) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
