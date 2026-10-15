import { configureStore } from "@reduxjs/toolkit"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { Provider } from "react-redux"
import { afterEach, describe, expect, it, vi } from "vitest"

import { navigationRequest } from "@application/navigation-request"
import repositoryStories from "@pages/repositories-show-page/stories"
import inboxStories from "@pages/notifications-page/stories"

import RepositoriesShowView from "../../views/repositories/show"

vi.mock("@hooks/use-page-data", () => ({
  usePageData: () => ({
    ...repositoryStories.args.data,
    notificationInbox: inboxStories.args.data.notificationInbox,
    notificationsPath: "/notifications",
    notificationsLabel: "Inbox",
    notificationsUnreadCount: 12,
  }),
}))

afterEach(() => vi.unstubAllGlobals())

describe("RepositoriesShowView() inbox", () => {
  it("loads on hover, navigates with real links, and updates the sidebar without marking anything read on entry", async () => {
    const store = configureStore({
      reducer: { navigationRequest: navigationRequest.reducer },
    })
    const notification = inboxStories.args.notifications[0]
    if (!notification) throw new Error("Expected an inbox notification fixture")

    const fetch = vi
      .fn()
      .mockResolvedValueOnce(
        Response.json({
          notifications: [notification],
          unreadCount: 12,
          nextBefore: null,
        }),
      )
      .mockResolvedValueOnce(Response.json({ version: 1, read: true, unreadCount: 11 }))
      .mockResolvedValueOnce(
        Response.json({
          notifications: [{ ...notification, id: 2, excerpt: "Another unread notification" }],
          unreadCount: 11,
          nextBefore: null,
        }),
      )
    vi.stubGlobal("fetch", fetch)
    render(
      <Provider store={store}>
        <RepositoriesShowView />
      </Provider>,
    )
    expect(fetch).not.toHaveBeenCalled()
    const inbox = screen.getByRole("link", { name: "Inbox, 12 unread items" })
    fireEvent.mouseEnter(inbox)
    const preview = await screen.findByRole("region", { name: "Inbox" })
    const row = await within(preview).findByRole("link", { name: /mentioned you/ })
    expect(row).toHaveAttribute("href", notification.path)
    expect(row).toHaveAttribute("data-sg-visit", "true")
    expect(within(preview).getByRole("link", { name: "View all" })).toHaveAttribute(
      "href",
      "/notifications",
    )
    expect(fetch).toHaveBeenCalledTimes(1)
    fireEvent.click(within(preview).getByRole("button", { name: "Mark as read: mona" }))
    await screen.findByRole("link", { name: "Inbox, 11 unread items" })
    await within(preview).findByText("Another unread notification")
    expect(
      within(preview).queryByRole("button", { name: "Mark as unread: mona" }),
    ).not.toBeInTheDocument()
    expect(fetch).toHaveBeenCalledTimes(3)
  })

  it("shows a retryable hover-preview error instead of an empty successful inbox", async () => {
    const store = configureStore({
      reducer: { navigationRequest: navigationRequest.reducer },
    })
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(null, { status: 503 })))
    render(
      <Provider store={store}>
        <RepositoriesShowView />
      </Provider>,
    )
    fireEvent.mouseEnter(screen.getByRole("link", { name: "Inbox, 12 unread items" }))
    await screen.findByText(inboxStories.args.data.notificationInbox.copy.error)
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument()
    expect(screen.queryByText("No activity yet")).not.toBeInTheDocument()
  })
})
