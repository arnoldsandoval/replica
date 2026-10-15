require Rails.root.join("app/models/local_development")

Rails.application.config.session_store \
  :cookie_store,
  key: LocalDevelopment.session_cookie_key,
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax
