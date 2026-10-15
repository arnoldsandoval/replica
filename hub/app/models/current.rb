# Holds authenticated request state for access across controller calls.
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :canvas_grant, :security_audit_context

  # Keeps extension identity separate from the browser session and its cookies.
  def user
    canvas_grant&.user || session&.user
  end
end
