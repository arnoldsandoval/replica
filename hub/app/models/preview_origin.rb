# Builds and recognizes the separate host used to serve one Build.
class PreviewOrigin
  PLACEHOLDER = "{build_id}"

  attr_reader :scheme

  # Validates an origin template containing one Build ID placeholder.
  def initialize(template, setting_name: "REPLICA_PREVIEW_ORIGIN_TEMPLATE")
    @setting_name = setting_name
    if template.to_s.scan(PLACEHOLDER).length != 1
      raise ArgumentError, "#{setting_name} must contain {build_id} once"
    end

    @template = template
    marker = "replicabuildid"
    marker += "x" while template.downcase.include?(marker)
    sample = parse_origin(template.sub(PLACEHOLDER, marker))
    if sample.host.scan(marker).length != 1
      raise ArgumentError, "#{setting_name} must place {build_id} in the host"
    end
    @scheme = sample.scheme
    @port = sample.port
    @frame_suffix = normalize_host(sample.host).split(".")
      .drop_while { !_1.include?(marker) }.drop(1).join(".")
    escaped_host = Regexp.escape(normalize_host(sample.host))
    @host_pattern = Regexp.new("\\A#{escaped_host.sub(Regexp.escape(marker), "(?<build_id>[1-9]\\d*)")}\\z")
  end

  class << self
    # Returns the configured preview origin template.
    def current
      new(Rails.configuration.x.preview_origin_template)
    end
  end

  # Returns the preview host for one positive Build ID.
  def host_for(build_id)
    uri_for(build_id).host
  end

  # Reports whether preview hosts share the Hub scheme and parent host.
  def same_site_with?(hub_origin)
    hub = URI.parse(hub_origin)
    sample_host = normalize_host(host_for(1))
    scheme == hub.scheme && sample_host.end_with?(".#{normalize_host(hub.host)}")
  rescue URI::InvalidURIError
    false
  end

  # Returns a Build ID when a host matches the configured preview pattern.
  def build_id(request_or_host)
    host = request_or_host.respond_to?(:host) ? request_or_host.host : request_or_host
    match = @host_pattern.match(normalize_host(host))
    match&.named_captures&.fetch("build_id", nil)&.to_i
  end

  # Returns an absolute URL on one Build's preview host.
  def url(build_id, path: "/", query: nil)
    uri = uri_for(build_id)
    uri.path = path
    uri.query = query.to_query if query.present?
    uri.to_s
  end

  # CSP permits a wildcard only for whole leftmost host labels, not b* or s*.
  def frame_source
    raise ArgumentError, "#{@setting_name} needs a parent domain for framing" if @frame_suffix.blank?

    source = "#{scheme}://*.#{@frame_suffix}"
    default_port = scheme == "https" ? 443 : 80
    @port == default_port ? source : "#{source}:#{@port}"
  end

  private

  # Returns a canonical DNS host for case-insensitive matching.
  def normalize_host(host)
    host.to_s.downcase.delete_suffix(".")
  end

  # Parses one complete origin without credentials or path data.
  def parse_origin(value)
    uri = URI.parse(value)
    valid = %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
    valid &&= uri.path.blank? || uri.path == "/"
    valid &&= uri.query.nil? && uri.fragment.nil?
    if !valid
      raise \
        ArgumentError,
        "#{@setting_name} must be an absolute HTTP or HTTPS origin. " \
          "It must not contain credentials, a non-root path, a query, or a fragment."
    end

    uri.path = ""
    uri
  rescue URI::InvalidURIError
    raise \
      ArgumentError,
      "#{@setting_name} must be an absolute HTTP or HTTPS origin. " \
        "It must not contain credentials, a non-root path, a query, or a fragment."
  end

  # Returns the parsed preview origin for one Build ID.
  def uri_for(build_id)
    unless build_id.to_s.match?(/\A[1-9]\d*\z/)
      raise ArgumentError, "Preview build ID must be a positive integer"
    end

    parse_origin(@template.sub(PLACEHOLDER, build_id.to_s))
  end
end
