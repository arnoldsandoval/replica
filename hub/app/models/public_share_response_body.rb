# Checks current public access before each outgoing chunk.
class PublicShareResponseBody
  # Wraps the existing body without reading artifacts inside a database lock.
  def initialize(body, share_link_id)
    @body = body
    @share_link_id = share_link_id
  end

  # Lets an approved chunk finish without holding the primary database lock.
  def each
    @body.each do |chunk|
      available = ShareLink.with_available_access(@share_link_id) { |allowed| allowed }
      break if !available

      yield chunk
    end
  ensure
    close
  end

  # Releases temporary response files even when policy interrupts transmission.
  def close
    @body.close if @body.respond_to?(:close)
  end
end
