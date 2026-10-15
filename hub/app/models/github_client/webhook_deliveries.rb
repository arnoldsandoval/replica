# Reads metadata and asks GitHub to resend bodies; Hub never downloads a backlog.
class GithubClient::WebhookDeliveries
  Page = Data.define(:deliveries, :cursor)

  # Uses the same transport and API version as every other App operation.
  def initialize(transport)
    @transport = transport
  end

  # Reads at most 100 attempts and validates the opaque next-page cursor.
  def page(token:, cursor: nil)
    validate_cursor!(cursor) if cursor
    path = "/app/hook/deliveries?per_page=100"
    path += "&cursor=#{CGI.escape(cursor)}" if cursor
    response = @transport.request(:get, path, token:, with_headers: true)
    deliveries = response.fetch(:body)
    raise GithubClient::InvalidResponse, "Invalid webhook delivery page" if !deliveries.is_a?(Array) || deliveries.size > 100

    deliveries.each { validate_delivery!(_1) }
    next_cursor = next_cursor!(response.fetch(:headers))
    raise GithubClient::InvalidResponse, "Repeated webhook delivery cursor" if cursor && next_cursor == cursor

    Page.new(deliveries:, cursor: next_cursor)
  end

  # An accepted request is not proof that the inbound delivery succeeded.
  def redeliver(id, token:)
    raise ArgumentError, "A positive GitHub attempt ID is required" if !id.is_a?(Integer) || !id.positive?

    @transport.request \
      :post, "/app/hook/deliveries/#{id}/attempts", token:,
      expected_status: [ 202 ], empty_response: true
  end

  private

  # Rejects malformed metadata before it can create recovery work.
  def validate_delivery!(delivery)
    valid = delivery.is_a?(Hash) &&
      delivery["id"].is_a?(Integer) && delivery["id"].positive? &&
      delivery["guid"].is_a?(String) && delivery["guid"].strip.present? && delivery["guid"].bytesize <= 255 &&
      delivery["event"].is_a?(String) && delivery["event"].bytesize.between?(1, 100) &&
      (delivery["action"].nil? || (delivery["action"].is_a?(String) && delivery["action"].bytesize <= 100)) &&
      (delivery["installation_id"].nil? ||
        (delivery["installation_id"].is_a?(Integer) && delivery["installation_id"].positive?)) &&
      (delivery["status_code"].nil? ||
        (delivery["status_code"].is_a?(Integer) &&
          (delivery["status_code"].zero? || delivery["status_code"].between?(100, 599)))) &&
      delivery["delivered_at"].is_a?(String)
    raise GithubClient::InvalidResponse, "Invalid webhook delivery metadata" if !valid

    delivered_at = Time.iso8601(delivery.fetch("delivered_at"))
    raise GithubClient::InvalidResponse, "Future webhook delivery metadata" if delivered_at > 5.minutes.from_now
  rescue ArgumentError
    raise GithubClient::InvalidResponse, "Invalid webhook delivery time"
  end

  # Only a same-origin link to this exact endpoint can supply the next cursor.
  def next_cursor!(headers)
    links = headers.fetch("link", []).join(",")
    targets = links.split(",").filter_map do |link|
      match = /\A\s*<([^>]+)>;\s*rel="([^"]+)"\s*\z/.match(link)
      raise GithubClient::InvalidResponse, "Invalid webhook pagination" if match.nil?

      match[1] if match[2].split.include?("next")
    end
    raise GithubClient::InvalidResponse, "Invalid webhook pagination" if targets.size > 1
    return if targets.empty?

    uri = URI.parse(targets.first)
    base = URI.parse(Rails.configuration.x.github_api_url)
    pairs = URI.decode_www_form(uri.query.to_s)
    values = pairs.to_h
    valid = uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port &&
      uri.userinfo.nil? && uri.fragment.nil? &&
      uri.path == "#{base.path.delete_suffix("/")}/app/hook/deliveries" &&
      pairs.size == values.size && values.keys.sort == %w[cursor per_page] && values["per_page"] == "100"
    raise GithubClient::InvalidResponse, "Invalid webhook pagination" if !valid

    validate_cursor!(values["cursor"])
    values["cursor"]
  rescue URI::InvalidURIError, ArgumentError
    raise GithubClient::InvalidResponse, "Invalid webhook pagination"
  end

  # Cursors stay opaque and are escaped, not interpreted as paths or page numbers.
  def validate_cursor!(cursor)
    valid = cursor.is_a?(String) && cursor.present? && cursor.bytesize <= 2048 &&
      !cursor.match?(/[\x00-\x1f\x7f]/)
    raise GithubClient::InvalidResponse, "Invalid webhook cursor" if !valid
  end
end
