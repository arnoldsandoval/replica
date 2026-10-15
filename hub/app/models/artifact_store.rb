require "pathname"

# Stores and retrieves files retained for Builds.
class ArtifactStore
  MAXIMUM_NAME_BYTES = 1_024
  # Keeps each path part within the common filesystem limit of 255 bytes.
  MAXIMUM_SEGMENT_BYTES = 255
  # A stored path adds builds/{id}/dist before up to 20 build output parts.
  MAXIMUM_SEGMENTS = 23
  # Local storage reserves this name for its own files.
  INTERNAL_SEGMENT = ".replica-internal"

  class Error < StandardError; end
  class TemporaryError < Error; end
  class InvalidName < Error; end
  class AlreadyExists < Error; end
  class Missing < Error; end
  class InvalidObject < Error; end

  class << self
    # Returns the storage provider configured for this Hub deployment.
    def current
      configuration = [
        Rails.configuration.x.artifact_store,
        Rails.configuration.x.artifact_root.to_s,
        Rails.configuration.x.azure_storage_account,
        Rails.configuration.x.azure_storage_container,
        Rails.configuration.x.azure_managed_identity_client_id
      ]
      return @current if @current_configuration == configuration

      (@current_mutex ||= Mutex.new).synchronize do
        return @current if @current_configuration == configuration

        @current = build_current
        @current_configuration = configuration
        @current
      end
    end

    private

    # Creates the configured storage provider.
    def build_current
      case Rails.configuration.x.artifact_store
      when "local"
        new(adapter: Local.new(root: Rails.configuration.x.artifact_root))
      when "azure"
        adapter = Azure.new \
          account: Rails.configuration.x.azure_storage_account,
          container: Rails.configuration.x.azure_storage_container
        new(adapter:)
      else
        raise Error, "Artifact storage provider is not supported: #{Rails.configuration.x.artifact_store}"
      end
    end
  end

  # Sets the local or Azure provider used to store files.
  def initialize(adapter:)
    @adapter = adapter
  end

  # Writes a new stored file and returns its size in bytes.
  def write(name, source:)
    adapter.write(validate_name(name, label: "object name"), source:)
  end

  # Copies one stored file into the destination and returns its size in bytes.
  def read(name, destination:)
    adapter.read(validate_name(name, label: "object name"), destination:)
  end

  # Reports whether a file exists with the exact storage name.
  def exist?(name)
    adapter.exist?(validate_name(name, label: "object name"))
  end

  # Returns sorted file names equal to or below one storage path.
  def list(prefix)
    prefix = validate_name(prefix, label: "prefix")
    adapter.list(prefix).map do |name|
      validate_stored_name(name).tap do
        if name != prefix && !name.start_with?("#{prefix}/")
          raise InvalidObject, "Artifact storage returned an object outside the requested prefix: #{name}"
        end
      end
    end
  end

  # Deletes the named file and every file below it; reports whether any existed.
  def delete_prefix(prefix)
    adapter.delete_prefix(validate_name(prefix, label: "prefix"))
  end

  private

  attr_reader :adapter

  # Returns a provider's file name or raises if that name is invalid.
  def validate_stored_name(name)
    validate_name(name, label: "stored object name")
  rescue InvalidName => error
    raise InvalidObject, error.message
  end

  # Returns a file name that local and Azure storage can both use safely.
  # Azure blobs: https://learn.microsoft.com/rest/api/storageservices/naming-and-referencing-containers--blobs--and-metadata#blob-names
  # POSIX names: https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/limits.h.html
  # Replica also requires unambiguous ASCII paths and reserves its internal name.
  def validate_name(name, label:)
    valid = name.is_a?(String) && name.valid_encoding? && name.match?(/\A[\x20-\x7e]+\z/)
    valid &&= name.bytesize <= MAXIMUM_NAME_BYTES
    valid &&= !name.include?("\\")
    segments = valid ? name.split("/", -1) : []
    valid &&= segments.length <= MAXIMUM_SEGMENTS
    valid &&= segments.none? do |segment|
      segment.empty? || %w[. ..].include?(segment) || segment == INTERNAL_SEGMENT ||
        segment.bytesize > MAXIMUM_SEGMENT_BYTES
    end
    if !valid
      raise \
        InvalidName,
        "Artifact #{label} must be a relative printable ASCII path of at most 1,024 bytes, " \
          "23 segments, and 255 bytes per segment. Segments cannot be empty, . or .., " \
          "or equal .replica-internal: #{name.inspect}"
    end

    name
  end
end
