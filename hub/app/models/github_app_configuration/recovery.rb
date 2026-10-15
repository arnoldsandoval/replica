# Reads protected host inputs without turning emergency repair into a browser bypass.
class GithubAppConfiguration::Recovery < ActiveRecord::AssociatedObject
  # Confirmation precedes file access; neither OAuth nor old credentials are required.
  def call!(confirmation:, client_secret_path:, private_key_path:)
    limits = GithubAppConfiguration::Administration
    raise limits::Denied, :confirmation_required if confirmation != limits::RECOVERY_PHRASE

    record.administration.recover_credentials! \
      confirmation:,
      client_secret: read_secret_file!(client_secret_path, limits::CLIENT_SECRET_LIMIT).strip,
      private_key: read_secret_file!(private_key_path, limits::PRIVATE_KEY_LIMIT)
  end

  private

  # Reject links, special files, broad permissions, and unbounded input before reading.
  def read_secret_file!(path, limit)
    raise GithubAppConfiguration::Administration::InvalidCredentials, "Invalid recovery input" if
      !path.is_a?(String) || path.blank?

    File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
      stat = file.stat
      valid = stat.file? && (stat.mode & 0o077).zero? &&
        (stat.uid == Process.uid || Process.uid.zero?) && stat.size.between?(1, limit)
      raise GithubAppConfiguration::Administration::InvalidCredentials, "Invalid recovery input" if !valid

      contents = file.read(limit + 1)
      raise GithubAppConfiguration::Administration::InvalidCredentials, "Invalid recovery input" if
        contents.nil? || contents.bytesize > limit

      contents
    end
  rescue SystemCallError, IOError, ArgumentError
    raise GithubAppConfiguration::Administration::InvalidCredentials, "Invalid recovery input"
  end
end
