import { act, fireEvent, render, screen, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { HubThemeProvider } from "@hooks/use-hub-theme"
import stories from "@pages/notifications-page/stories"
import type { NotificationsPageData } from "@pages/notifications-page/types"

import NotificationsView from "../../views/notifications"

vi.mock("@hooks/use-page-data", () => ({
  usePageData: (): NotificationsPageData => ({
    ...stories.args.data,
    repository: stories.args.data.repository
      ? {
          ...stories.args.data.repository,
          analyticsLabel: "Analytics",
          analyticsPath: "/repositories/2001/analytics",
        }
      : null,
    securityAuditLabel: "Security audit",
    securityAuditPath: "/repositories/2001/security-audit",
    administrationLinks: [
      { section: "github", label: "GitHub App", path: "/github-app" },
      { section: "admins", label: "Hub administrators", path: "/hub-admins" },
      { section: "sharing", label: "Public sharing", path: "/sharing-settings" },
      { section: "sessions", label: "Sessions", path: "/session-revocation" },
    ],
  }),
}))

afterEach(() => vi.unstubAllGlobals())

describe("NotificationsView()", () => {
  it.each([false, true])(
    "keeps the account theme controls with collapsed=%s",
    async (collapsed) => {
      vi.stubGlobal(
        "fetch",
        vi
          .fn()
          .mockResolvedValue(
            Response.json({ notifications: [], nextBefore: null, unreadCount: 0 }),
          ),
      )
      render(<NotificationsView />, { wrapper: HubThemeProvider })
      await screen.findByText("No activity yet")
      if (collapsed) {
        fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
      }
      fireEvent.click(screen.getByRole("button", { name: stories.args.data.accountMenuLabel }))
      for (const name of ["System", "Light", "Dark"]) {
        expect(screen.getByRole("menuitemradio", { name })).toBeInTheDocument()
      }
      fireEvent.click(screen.getByRole("menuitemradio", { name: "Dark" }))
      expect(document.documentElement).toHaveAttribute("data-color-mode", "dark")
    },
  )

  it("loads and displays a new comment notification for the prototype owner", async () => {
    const notification = stories.args.notifications[0]
    if (!notification) throw new Error("Expected an inbox notification fixture")

    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        Response.json({
          notifications: [{ ...notification, kind: "comment", excerpt: "New prototype feedback" }],
          nextBefore: null,
          unreadCount: 1,
        }),
      ),
    )
    render(<NotificationsView />)

    expect(await screen.findByText("New prototype feedback")).toBeInTheDocument()
    expect(screen.getByText("commented on your prototype")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Mark as read: mona" })).toBeInTheDocument()
  })

  it.each([false, true])(
    "retains analytics and administration navigation with collapsed=%s",
    async (collapsed) => {
      vi.stubGlobal(
        "fetch",
        vi
          .fn()
          .mockResolvedValue(
            Response.json({ notifications: [], nextBefore: null, unreadCount: 0 }),
          ),
      )
      render(<NotificationsView />)
      await screen.findByText("No activity yet")
      if (collapsed) {
        fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
      }
      for (const [name, path] of [
        ["Analytics", "/repositories/2001/analytics"],
        ["Security audit", "/repositories/2001/security-audit"],
        ["GitHub App", "/github-app"],
        ["Hub administrators", "/hub-admins"],
        ["Public sharing", "/sharing-settings"],
        ["Sessions", "/session-revocation"],
      ]) {
        expect(screen.getByRole("link", { name })).toHaveAttribute("href", path)
      }
    },
  )

  it.each([false, true])(
    "keeps the hover preview available and synchronized on the inbox page with collapsed=%s",
    async (collapsed) => {
      const notification = stories.args.notifications[0]
      if (!notification) throw new Error("Expected an inbox notification fixture")

      const readNotification = {
        ...notification,
        id: 2,
        kind: "reply" as const,
        read: true,
        excerpt: "Previously read reply",
      }
      const page = {
        notifications: [notification, readNotification],
        nextBefore: null,
        unreadCount: 1,
      }
      const fetch = vi
        .fn()
        .mockResolvedValueOnce(Response.json(page))
        .mockResolvedValueOnce(Response.json({ ...page, notifications: [notification] }))
        .mockResolvedValueOnce(Response.json(page))
        .mockResolvedValueOnce(Response.json({ version: 1, read: true, unreadCount: 0 }))
        .mockResolvedValueOnce(
          Response.json({
            ...page,
            notifications: [{ ...notification, read: true, version: 1 }, readNotification],
            unreadCount: 0,
          }),
        )
        .mockResolvedValueOnce(Response.json({ version: 2, read: false, unreadCount: 1 }))
      vi.stubGlobal("fetch", fetch)
      render(<NotificationsView />)
      const fullPage = await screen.findByRole("region", { name: "Inbox" })
      await within(fullPage).findByText("Previously read reply")
      if (collapsed) {
        fireEvent.click(screen.getByRole("button", { name: "Collapse sidebar" }))
      }
      fireEvent.click(within(fullPage).getByRole("button", { name: "Unread" }))
      await within(fullPage).findByRole("button", { name: "Mark as read: mona" })
      expect(within(fullPage).queryByText("Previously read reply")).not.toBeInTheDocument()
      fireEvent.mouseEnter(screen.getByRole("link", { name: "Inbox, 1 unread items" }))
      const preview = screen
        .getAllByRole("region", { name: "Inbox" })
        .find((region) => region.dataset.mode === "preview")
      if (!preview) throw new Error("Expected the inbox hover preview")

      await within(preview).findByText(notification.excerpt)
      expect(within(preview).queryByText("Previously read reply")).not.toBeInTheDocument()
      expect(fetch).toHaveBeenNthCalledWith(
        3,
        new URL("http://localhost:3000/notifications/inbox?limit=10&unread=true"),
        { credentials: "same-origin" },
      )
      fireEvent.click(within(preview).getByRole("button", { name: "Mark as read: mona" }))
      await within(fullPage).findByText("You are all caught up")
      expect(screen.getByRole("link", { name: "Inbox" })).toBeInTheDocument()
      fireEvent.click(within(fullPage).getByRole("button", { name: "All" }))
      await within(fullPage).findByText("Previously read reply")
      const row = within(fullPage).getByText(notification.excerpt).closest("li")
      if (!row) throw new Error("Expected the updated notification row")

      fireEvent.click(within(row).getByRole("button", { name: "Mark as unread: mona" }))
      await within(preview).findByRole("button", { name: "Mark as read: mona" })
      expect(screen.getByRole("link", { name: "Inbox, 1 unread items" })).toBeInTheDocument()
      expect(fetch).toHaveBeenLastCalledWith("/notifications/1", {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": stories.args.data.authenticityToken,
        },
        body: JSON.stringify({ notification: { read: false, version: 1 } }),
      })
    },
  )

  it("sends the observed version and keeps the message mounted while updating its read state and count", async () => {
    const notification = stories.args.notifications[0]
    const fetch = vi
      .fn()
      .mockResolvedValueOnce(
        Response.json({ notifications: [notification], nextBefore: null, unreadCount: 1 }),
      )
      .mockResolvedValueOnce(Response.json({ version: 1, read: true, unreadCount: 0 }))
    vi.stubGlobal("fetch", fetch)
    render(<NotificationsView />)
    fireEvent.click(await screen.findByRole("button", { name: "Mark as read: mona" }))
    await screen.findByRole("button", { name: "Mark as unread: mona" })
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(screen.getByRole("link", { name: "Inbox" })).toBeInTheDocument()
    expect(fetch).toHaveBeenCalledWith("/notifications/1", {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": stories.args.data.authenticityToken,
      },
      body: JSON.stringify({ notification: { read: true, version: 0 } }),
    })
  })

  it.each([200, 409])(
    "ignores an old read update with status %s after switching filters",
    async (status) => {
      let finish!: (response: Response) => void
      const pending = new Promise<Response>((resolve) => {
        finish = resolve
      })
      const fetch = vi
        .fn()
        .mockResolvedValueOnce(
          Response.json({
            notifications: stories.args.notifications,
            nextBefore: null,
            unreadCount: 1,
          }),
        )
        .mockReturnValueOnce(pending)
        .mockResolvedValueOnce(
          Response.json({ notifications: [], nextBefore: null, unreadCount: 0 }),
        )
      vi.stubGlobal("fetch", fetch)
      render(<NotificationsView />)
      fireEvent.click(await screen.findByRole("button", { name: "Mark as read: mona" }))
      fireEvent.click(screen.getByRole("button", { name: "Unread" }))
      await screen.findByText("You are all caught up")
      await act(async () => {
        finish(new Response(null, { status }))
        await pending
      })
      expect(screen.getByText("You are all caught up")).toBeInTheDocument()
      expect(screen.queryByRole("alert")).not.toBeInTheDocument()
      expect(fetch).toHaveBeenCalledTimes(3)
    },
  )
})
