# Streams a temporary response file and deletes it afterward.
class ArtifactResponseBody
  # Keeps the file open until Rack finishes sending the response.
  def initialize(file)
    @file = file
  end

  # Sends the file in fixed-size chunks.
  def each
    while (chunk = @file.read(64.kilobytes))
      break if chunk.empty?

      yield chunk
    end
  ensure
    close
  end

  # Deletes the temporary response file.
  def close
    @file.close!
  end
end

# Sends one stored Build file without exposing its storage service.
module ArtifactRespondable
  private

  # Copies one stored file for the response and adds optional content at the end.
  def send_artifact(
    name,
    content_type:,
    filename: nil,
    missing: :not_found,
    fallback: nil,
    resource_policy: "same-origin",
    append: nil
  )
    store = ArtifactStore.current
    file = Tempfile.new([ "replica-artifact-response-", ".bin" ], binmode: true)
    store.read(name, destination: file)
    file.write(append) if append
    file.rewind

    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cross-Origin-Resource-Policy"] = resource_policy if resource_policy
    response.headers["Content-Type"] = content_type
    response.headers["Content-Disposition"] = if filename
      ActionDispatch::Http::ContentDisposition.format(disposition: "inline", filename:)
    else
      "inline"
    end
    self.response_body = ArtifactResponseBody.new(file)
  rescue ArtifactStore::Missing
    file&.close!
    if fallback
      return send_artifact \
        fallback,
        content_type:,
        filename:,
        missing:,
        resource_policy:,
        append:
    end
    raise if missing == :raise

    head :not_found
  rescue ArtifactStore::InvalidName
    file&.close!
    raise if missing == :raise

    head :not_found
  rescue ArtifactStore::TemporaryError
    file&.close!
    head :service_unavailable
  rescue StandardError
    file&.close!
    raise
  end
end
