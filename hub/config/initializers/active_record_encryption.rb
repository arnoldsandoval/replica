key_generator = Rails.application.key_generator
production_runtime = Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?

encryption_value = lambda do |name, purpose|
  return ENV.fetch(name) if production_runtime

  ENV.fetch(name) { key_generator.generate_key(purpose, 32) }
end

primary_key = encryption_value.call \
  "REPLICA_DATABASE_ENCRYPTION_PRIMARY_KEY",
  "replica-hub/database-encryption/primary"
deterministic_key = encryption_value.call \
  "REPLICA_DATABASE_ENCRYPTION_DETERMINISTIC_KEY",
  "replica-hub/database-encryption/deterministic"
key_derivation_salt = encryption_value.call \
  "REPLICA_DATABASE_ENCRYPTION_KEY_DERIVATION_SALT",
  "replica-hub/database-encryption/salt"

ActiveRecord::Encryption.configure \
  primary_key:,
  deterministic_key:,
  key_derivation_salt:
