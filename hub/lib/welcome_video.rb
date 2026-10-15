module WelcomeVideo
  # Returns a direct video asset when the configured video is not a supported YouTube URL.
  def self.url
    value = Rails.configuration.x.welcome_video_url
    return if value.blank? || youtube_video_id(value)

    asset_url(value, "REPLICA_WELCOME_VIDEO_URL")
  end

  # Converts supported YouTube watch links into privacy-enhanced embeds.
  def self.embed_url
    video_id = youtube_video_id(Rails.configuration.x.welcome_video_url)
    "https://www.youtube-nocookie.com/embed/#{video_id}" if video_id
  end

  # Supplies an optional still image before playback starts.
  def self.poster_url
    asset_url(Rails.configuration.x.welcome_video_poster_url, "REPLICA_WELCOME_VIDEO_POSTER_URL")
  end

  # Limits embedded video frames to YouTube's privacy-enhanced host.
  def self.frame_origin
    "https://www.youtube-nocookie.com" if embed_url
  end

  def self.youtube_video_id(value)
    return if value.blank?

    uri = URI.parse(value)
    host = uri.host&.downcase
    youtube_hosts = %w[youtube.com www.youtube.com m.youtube.com youtu.be www.youtube-nocookie.com]
    return unless youtube_hosts.include?(host)
    raise ArgumentError, "REPLICA_WELCOME_VIDEO_URL must be a secure YouTube URL" unless
      uri.is_a?(URI::HTTPS) && uri.userinfo.nil? && uri.port == uri.default_port

    id = case host
    when "youtube.com", "www.youtube.com", "m.youtube.com"
      URI.decode_www_form(uri.query.to_s).to_h["v"] if uri.path == "/watch"
    when "youtu.be"
      uri.path.match(%r{\A/([A-Za-z0-9_-]{11})/?\z})&.captures&.first
    when "www.youtube-nocookie.com"
      uri.path.match(%r{\A/embed/([A-Za-z0-9_-]{11})/?\z})&.captures&.first
    end

    raise ArgumentError, "REPLICA_WELCOME_VIDEO_URL must be a YouTube video URL" unless
      /\A[A-Za-z0-9_-]{11}\z/.match?(id.to_s)

    id
  rescue URI::InvalidURIError, ArgumentError => error
    raise error if error.message.start_with?("REPLICA_WELCOME_VIDEO_URL")

    raise ArgumentError, "REPLICA_WELCOME_VIDEO_URL must be a valid URL"
  end
  private_class_method :youtube_video_id

  def self.asset_url(value, setting)
    return if value.blank?

    uri = URI.parse(value)
    valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
    valid ||= Rails.env.development? && value.start_with?("/") && !value.start_with?("//")
    raise ArgumentError, "#{setting} must be an HTTPS asset URL" unless valid

    value
  rescue URI::InvalidURIError
    raise ArgumentError, "#{setting} must be an HTTPS asset URL"
  end
  private_class_method :asset_url

  # Limits media loading to the configured video host rather than all HTTPS hosts.
  def self.origin
    value = url
    return "'self'" if value.nil? || value.start_with?("/")

    uri = URI.parse(value)
    "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
  end
end
