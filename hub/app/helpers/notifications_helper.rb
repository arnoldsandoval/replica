module NotificationsHelper
  # Counts unread activity only after confirming current access to every source repository.
  def notifications_unread_count
    @notifications_unread_count ||= Notification.visible_to(Current.user).where(read_at: nil).count
  end

  # Retains the boolean contract for callers that do not display a counter.
  def notifications_unread?
    notifications_unread_count.positive?
  end
end
