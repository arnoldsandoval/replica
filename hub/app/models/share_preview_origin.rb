# Builds and recognizes the separate host used by public share previews.
class SharePreviewOrigin < PreviewOrigin
  class << self
    # Returns the configured public share preview origin template.
    def current
      new \
        Rails.configuration.x.share_preview_origin_template,
        setting_name: "REPLICA_SHARE_PREVIEW_ORIGIN_TEMPLATE"
    end
  end
end
