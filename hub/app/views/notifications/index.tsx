import { useNotificationInbox } from "@hooks/use-notification-inbox"
import { usePageData } from "@hooks/use-page-data"
import { useRepositoryInbox } from "@hooks/use-repository-inbox"
import { NotificationsPage } from "@pages/notifications-page"
import type { NotificationsPageData } from "@pages/notifications-page/types"

export default function NotificationsView() {
  const pageData = usePageData<NotificationsPageData>()
  const inbox = useNotificationInbox({
    path: pageData.notificationInbox.path,
    authenticityToken: pageData.authenticityToken,
    initialUnreadCount: pageData.notificationsUnreadCount,
    onReadChange: (id, saved) => data.liveInbox?.onReadUpdate(id, saved),
  })
  const data: NotificationsPageData = useRepositoryInbox(
    { ...pageData, notificationsUnreadCount: inbox.unreadCount },
    {
      onReadChange: inbox.onReadUpdate,
      onUnreadCountChange: inbox.onUnreadCountChange,
    },
  )

  return <NotificationsPage data={data} {...inbox} />
}
