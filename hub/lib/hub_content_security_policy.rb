# Restricts trusted Hub pages without restricting arbitrary prototype assets.
module HubContentSecurityPolicy
  # Keeps development transport allowances out of the production policy.
  def self.build(development:, policy: ActionDispatch::ContentSecurityPolicy.new)
    policy.tap do |policy|
      policy.default_src :self
      policy.base_uri :none
      policy.object_src :none
      policy.frame_ancestors :none
      policy.script_src :self
      policy.script_src_attr :none
      # Primer and preview controls position elements with inline styles.
      policy.style_src :self, :unsafe_inline
      policy.font_src :self
      # GitHub and Enterprise can return avatars from separate HTTPS hosts.
      policy.img_src :self, :https, :data
      policy.media_src :self, -> { WelcomeVideo.origin }
      policy.connect_src :self, -> { Rails.configuration.x.hub_origin.sub(/\Ahttp/, "ws").delete_suffix("/") }
      policy.frame_src \
        :self,
        -> { PreviewOrigin.current.frame_source },
        -> { SharePreviewOrigin.current.frame_source },
        -> { WelcomeVideo.frame_origin || "'self'" }
      policy.form_action :self, -> { Rails.configuration.x.github_url.delete_suffix("/") }
      policy.worker_src :none

      if development
        origin = URI(Rails.configuration.x.hub_origin)
        origin.port = ViteRuby.config.port
        vite_origins = [ origin.to_s.delete_suffix("/"), ViteRuby.config.origin ].uniq
        policy.script_src :self, *vite_origins
        policy.style_src :self, :unsafe_inline, *vite_origins
        policy.font_src :self, *vite_origins
        policy.img_src :self, :https, :data, *vite_origins
        policy.connect_src \
          :self,
          -> { Rails.configuration.x.hub_origin.sub(/\Ahttp/, "ws").delete_suffix("/") },
          *vite_origins,
          *vite_origins.map { _1.sub(/\Ahttp/, "ws") }
      end
    end
  end
end
