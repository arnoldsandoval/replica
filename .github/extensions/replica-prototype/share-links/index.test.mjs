import assert from "node:assert/strict"
import { describe, it } from "node:test"

import { createShareLinks } from "./index.mjs"

const link = {
  id: 1,
  url: "https://replica.example/share/12345678-1234-1234-1234-123456789abc",
  buildNumber: 2,
  label: "Review",
  expiresAt: null,
}
const listed = {
  ...link,
  createdAt: "2026-10-05T07:00:00Z",
  createdBy: { login: "octocat", name: null },
}

function fixture() {
  const calls = []
  const opened = []
  let checkout = {
    repository: "github/prototype",
    branch: "prototype/welcome",
  }
  let prototype = {
    id: 1,
    repositoryId: 2001,
    branch: checkout.branch,
    canManageShareLinks: true,
    published: true,
    build: { number: 2 },
  }
  function defaultResponse(route, options) {
    return route.startsWith("/api/canvas/prototype?")
      ? prototype
      : options.method === "POST"
        ? link
        : options.method === "DELETE"
          ? {}
          : { shareLinks: [listed], hasMore: false, nextCursor: null }
  }
  let respond = defaultResponse
  const savedPreferences = new Map()
  const preferences = {
    read: async (identity) => savedPreferences.get(identity) ?? false,
    write: async (identity, included) => {
      savedPreferences.set(identity, included)
    },
  }
  const hub = {
    origin: "https://replica.example",
    checkout: async () => checkout,
    request: async (route, options) => {
      calls.push({ route, ...options })
      options.connectionScope.identity ||= "test-connection"
      return respond(route, options)
    },
  }
  const sharing = createShareLinks(
    async () => hub,
    async (url) => {
      opened.push(url)
      return { ok: true }
    },
    preferences,
  )
  return {
    sharing,
    calls,
    opened,
    hub,
    preferences,
    reopen: () =>
      createShareLinks(
        async () => hub,
        async () => ({ ok: true }),
        preferences,
      ),
    changeCheckout: (value) => {
      checkout = value
    },
    changePrototype: (value) => {
      prototype = { ...prototype, ...value }
    },
    respond: (value) => {
      respond = value
    },
  }
}

describe("createShareLinks()", () => {
  it("uses the Hub expiration policy without dispatching disallowed creation", async () => {
    const f = fixture()
    f.changePrototype({
      shareLinkExpirationOptions: ["one_day", "seven_days"],
    })
    const context = await f.sharing("context")
    assert.deepEqual(context.prototype.shareLinkExpirationOptions, ["one_day", "seven_days"])
    for (const expiration of ["never", "thirty_days"]) {
      await assert.rejects(
        f.sharing("create", {
          target: context.target,
          buildNumber: 2,
          label: "Review",
          expiration,
        }),
        { statusCode: 422 },
      )
    }
    assert.equal(f.calls.length, 1)
    for (const expiration of ["one_day", "seven_days"]) {
      await f.sharing("create", {
        target: context.target,
        buildNumber: 2,
        label: "Review",
        expiration,
      })
      assert.equal(f.calls.at(-1).body.share_link.expiration, expiration)
    }
  })

  for (const options of [null, [], ["later"], ["seven_days", "seven_days"]]) {
    it(`rejects malformed Hub expiration options ${JSON.stringify(options)}`, async () => {
      const f = fixture()
      f.changePrototype({ shareLinkExpirationOptions: options })
      await assert.rejects(f.sharing("context"), {
        statusCode: 502,
        message: "Hub returned an invalid share-link expiration policy.",
      })
      assert.equal(f.calls.length, 1)
    })
  }

  it("forgets links and pending verification after creator access changes without disabling sharing", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    await f.sharing("list", { target })
    f.respond(() => {
      throw Object.assign(new Error("Verify with GitHub"), {
        statusCode: 403,
        code: "fresh_authorization_required",
        authorization: {
          url: "https://replica.example/authorization/12345678-1234-1234-1234-123456789abc",
          expiresAt: new Date(Date.now() + 60_000).toISOString(),
        },
      })
    })
    await assert.rejects(
      f.sharing("create", {
        target,
        buildNumber: 2,
        label: "Review",
        expiration: "never",
      }),
      { code: "fresh_authorization_required" },
    )
    f.respond(() => {
      throw Object.assign(new Error("Repository access changed"), {
        statusCode: 403,
        code: "creator_access_changed",
      })
    })
    await assert.rejects(
      f.sharing("create", {
        target,
        buildNumber: 2,
        label: "Review",
        expiration: "seven_days",
      }),
      { code: "creator_access_changed" },
    )
    await assert.rejects(f.sharing("open", { target, id: listed.id }), {
      statusCode: 404,
    })
    await assert.rejects(f.sharing("authorize", { target }), {
      statusCode: 410,
    })
    assert.deepEqual(f.opened, [])
    f.respond(() => ({
      shareLinks: [listed],
      hasMore: false,
      nextCursor: null,
    }))
    assert.deepEqual((await f.sharing("list", { target })).shareLinks, [listed])
  })

  it("projects deployment-disabled policy without dispatching creation or opening a browser", async () => {
    const f = fixture()
    f.changePrototype({ publicSharingEnabled: false })
    const { target } = await f.sharing("context")
    await assert.rejects(
      f.sharing("create", {
        target,
        buildNumber: 2,
        label: "Review",
        expiration: "never",
      }),
      { statusCode: 403, code: "public_sharing_disabled" },
    )
    assert.equal(f.calls.length, 1)
    assert.deepEqual(f.opened, [])
  })

  it("forgets retrieved links after a policy denial and requires a new context", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    await f.sharing("list", { target })
    f.respond(() => {
      throw Object.assign(new Error("Sharing disabled"), {
        statusCode: 403,
        code: "public_sharing_disabled",
      })
    })
    await assert.rejects(f.sharing("list", { target }), {
      code: "public_sharing_disabled",
    })
    await assert.rejects(f.sharing("open", { target, id: listed.id }), {
      code: "public_sharing_disabled",
    })
    assert.deepEqual(f.opened, [])
  })

  for (const denial of [
    "disabled prototype",
    "public_sharing_disabled",
    "public_sharing_changed",
    "creator_access_changed",
  ]) {
    it(`rejects an older list after ${denial} without restoring URLs or challenges`, async () => {
      const f = fixture()
      const { target } = await f.sharing("context")
      await f.sharing("list", { target })
      f.respond(() => {
        throw Object.assign(new Error("Verify with GitHub"), {
          statusCode: 403,
          code: "fresh_authorization_required",
          authorization: {
            url: "https://replica.example/authorization/12345678-1234-1234-1234-123456789abc",
            expiresAt: new Date(Date.now() + 60_000).toISOString(),
          },
        })
      })
      await assert.rejects(
        f.sharing("create", {
          target,
          buildNumber: 2,
          label: "Review",
          expiration: "never",
        }),
        { code: "fresh_authorization_required" },
      )
      let finish
      const page = new Promise((resolve) => {
        finish = resolve
      })
      f.respond((route) => {
        if (!route.startsWith("/api/canvas/prototype?")) return page
        if (denial === "disabled prototype")
          return {
            id: 1,
            canManageShareLinks: true,
            publicSharingEnabled: false,
          }
        throw Object.assign(new Error("Sharing access changed"), {
          statusCode: 403,
          code: denial,
        })
      })
      const reading = f.sharing("list", { target })
      const rejected = assert.rejects(reading, { code: "stale_share_target" })
      await new Promise((resolve) => setImmediate(resolve))
      await assert.rejects(f.sharing("open", { target, id: listed.id }), {
        code: denial === "disabled prototype" ? "public_sharing_disabled" : denial,
      })
      finish({ shareLinks: [listed], hasMore: false, nextCursor: null })
      await rejected
      const disabled = ["disabled prototype", "public_sharing_disabled"].includes(denial)
      await assert.rejects(f.sharing("open", { target, id: listed.id }), {
        statusCode: disabled ? 403 : 404,
      })
      await assert.rejects(f.sharing("authorize", { target }), {
        statusCode: disabled ? 403 : 410,
      })
      assert.deepEqual(f.opened, [])
    })
  }

  it("rejects an older authorization challenge after a creator denial", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    let denyCreation
    const challenge = new Promise((_, reject) => {
      denyCreation = reject
    })
    f.respond((_, options) => {
      if (options.method === "POST") return challenge
      throw Object.assign(new Error("Repository access changed"), {
        statusCode: 403,
        code: "creator_access_changed",
      })
    })
    const creation = f.sharing("create", {
      target,
      buildNumber: 2,
      label: "Review",
      expiration: "never",
    })
    const rejected = assert.rejects(creation, { code: "stale_share_target" })
    await new Promise((resolve) => setImmediate(resolve))
    await assert.rejects(f.sharing("list", { target }), {
      code: "creator_access_changed",
    })
    denyCreation(
      Object.assign(new Error("Verify with GitHub"), {
        statusCode: 403,
        code: "fresh_authorization_required",
        authorization: {
          url: "https://replica.example/authorization/12345678-1234-1234-1234-123456789abc",
          expiresAt: new Date(Date.now() + 60_000).toISOString(),
        },
      }),
    )
    await rejected
    await assert.rejects(f.sharing("authorize", { target }), {
      statusCode: 410,
    })
    assert.deepEqual(f.opened, [])
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
  })

  it("requires a fresh list when creation completes after an access denial", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    let finish
    const response = new Promise((resolve) => {
      finish = resolve
    })
    f.respond((_, options) => {
      if (options.method === "POST") return response
      throw Object.assign(new Error("Repository access changed"), {
        statusCode: 403,
        code: "creator_access_changed",
      })
    })
    const input = {
      target,
      buildNumber: 2,
      label: "Review",
      expiration: "seven_days",
    }
    const creation = f.sharing("create", input)
    const rejected = assert.rejects(creation, {
      code: "share_delivery_unknown",
    })
    await new Promise((resolve) => setImmediate(resolve))
    await assert.rejects(f.sharing("list", { target }), {
      code: "creator_access_changed",
    })
    finish(link)
    await rejected
    await assert.rejects(f.sharing("create", input), {
      code: "share_delivery_unknown",
    })
    await assert.rejects(f.sharing("open", { target, id: link.id }), {
      statusCode: 404,
    })
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
    assert.deepEqual(f.opened, [])
    f.respond(() => ({ shareLinks: [], hasMore: false, nextCursor: null }))
    await f.sharing("list", { target })
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
  })

  for (const denial of ["creator_access_changed", "public_sharing_changed"]) {
    it(`requires a fresh list when a dispatched creation times out after ${denial}`, async () => {
      const f = fixture()
      const { target } = await f.sharing("context")
      let rejectCreation
      const response = new Promise((_, reject) => {
        rejectCreation = reject
      })
      f.respond((_, options) => {
        if (options.method === "POST") return response
        throw Object.assign(new Error("Sharing access changed"), {
          statusCode: 403,
          code: denial,
        })
      })
      const input = {
        target,
        buildNumber: 2,
        label: "Review",
        expiration: "seven_days",
      }
      const creation = f.sharing("create", input)
      const rejected = assert.rejects(creation, {
        code: "share_delivery_unknown",
      })
      await new Promise((resolve) => setImmediate(resolve))
      await assert.rejects(f.sharing("list", { target }), { code: denial })
      rejectCreation(
        Object.assign(new Error("Timed out"), {
          deliveryPhase: "after_dispatch",
        }),
      )
      await rejected
      await assert.rejects(f.sharing("create", input), {
        code: "share_delivery_unknown",
      })
      assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
      f.respond(() => ({ shareLinks: [], hasMore: false, nextCursor: null }))
      await f.sharing("list", { target })
      assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
      f.respond(() => link)
      assert.deepEqual(await f.sharing("create", input), link)
      assert.equal(f.calls.filter((call) => call.method === "POST").length, 2)
      assert.deepEqual(f.opened, [])
    })
  }

  for (const action of ["open", "authorize"]) {
    it(`forgets links and challenges when sharing is disabled before ${action}`, async () => {
      const f = fixture()
      const { target } = await f.sharing("context")
      await f.sharing("list", { target })
      f.respond((route, options) => {
        if (options.method === "POST")
          throw Object.assign(new Error("Verify with GitHub"), {
            statusCode: 403,
            code: "fresh_authorization_required",
            authorization: {
              url: "https://replica.example/authorization/12345678-1234-1234-1234-123456789abc",
              expiresAt: new Date(Date.now() + 60_000).toISOString(),
            },
          })
        return {
          id: 1,
          canManageShareLinks: true,
          publicSharingEnabled: false,
        }
      })
      if (action === "authorize")
        await assert.rejects(
          f.sharing("create", {
            target,
            buildNumber: 2,
            label: "Review",
            expiration: "never",
          }),
          { code: "fresh_authorization_required" },
        )
      await assert.rejects(f.sharing(action, { target, id: listed.id }), {
        code: "public_sharing_disabled",
      })
      const count = f.calls.length
      await assert.rejects(f.sharing("list", { target }), {
        code: "public_sharing_disabled",
      })
      assert.equal(f.calls.length, count)
      assert.deepEqual(f.opened, [])
    })
  }
  it("remembers the local choice across new sharing instances without changing Hub records", async () => {
    const f = fixture()
    const context = await f.sharing("context")
    assert.equal(context.controlSettingsIncluded, false)
    assert.deepEqual(
      await f.sharing("controls-preference", {
        target: context.target,
        included: true,
      }),
      { included: true },
    )
    assert.equal(f.calls.length, 1)
    const reopened = f.reopen()
    const fresh = await reopened("context")
    assert.equal(fresh.controlSettingsIncluded, true)
    f.changePrototype({ id: 2 })
    assert.equal((await reopened("context")).controlSettingsIncluded, false)
    f.changePrototype({ id: 1 })
    const original = await reopened("context")
    await reopened("controls-preference", {
      target: original.target,
      included: false,
    })
    assert.equal((await f.reopen()("context")).controlSettingsIncluded, false)
    assert.ok(f.calls.every((call) => !call.method))
  })

  for (const mode of ["reader", "sharing disabled"]) {
    it(`saves internal sharing preferences for ${mode} without granting public sharing`, async () => {
      const f = fixture()
      f.changePrototype(
        mode === "reader" ? { canManageShareLinks: false } : { publicSharingEnabled: false },
      )
      const { target } = await f.sharing("context")
      assert.deepEqual(await f.sharing("controls-preference", { target, included: true }), {
        included: true,
      })
      const reopened = f.reopen()
      const context = await reopened("context")
      assert.equal(context.controlSettingsIncluded, true)
      for (const action of ["list", "create", "delete", "open", "authorize"])
        await assert.rejects(reopened(action, { target: context.target }), {
          statusCode: 403,
        })
      await reopened("controls-preference", {
        target: context.target,
        included: false,
      })
      assert.equal((await f.reopen()("context")).controlSettingsIncluded, false)
      assert.ok(f.calls.every((call) => call.route.startsWith("/api/canvas/prototype?")))
      assert.deepEqual(f.opened, [])

      f.changeCheckout({
        repository: "github/prototype",
        branch: "prototype/changed",
      })
      await assert.rejects(f.sharing("controls-preference", { target, included: true }), {
        code: "stale_share_target",
      })
    })
  }

  it("validates checkbox values and rejects expired or changed targets before saving", async () => {
    const f = fixture()
    const context = await f.sharing("context")
    for (const included of ["true", 1, null, {}])
      await assert.rejects(f.sharing("controls-preference", { target: context.target, included }), {
        statusCode: 422,
      })
    const write = f.preferences.write
    const writes = []
    f.preferences.write = async (...args) => {
      writes.push(args)
      await write(...args)
    }
    await assert.rejects(f.sharing("controls-preference", { target: "expired", included: true }), {
      code: "stale_share_target",
    })
    f.changeCheckout({
      repository: "github/prototype",
      branch: "prototype/changed",
    })
    await assert.rejects(
      f.sharing("controls-preference", {
        target: context.target,
        included: true,
      }),
      { code: "stale_share_target" },
    )
    assert.deepEqual(writes, [])
  })

  it("surfaces preference read and write failures without blocking ordinary link reads", async () => {
    const f = fixture()
    f.preferences.read = async () => {
      throw new Error("Unreadable")
    }
    f.preferences.write = async () => {
      throw new Error("Unwritable")
    }
    const context = await f.sharing("context")
    assert.equal(context.controlSettingsIncluded, false)
    assert.match(context.controlSettingsError, /could not be read/)
    assert.deepEqual((await f.sharing("list", { target: context.target })).shareLinks, [listed])
    await assert.rejects(
      f.sharing("controls-preference", {
        target: context.target,
        included: true,
      }),
      { statusCode: 500, message: /could not be saved/ },
    )
  })

  it("adds bounded control settings only to the verified cached public URL", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    await f.sharing("list", { target })
    const query = new URLSearchParams({
      "rc.page.title": JSON.stringify("Configured"),
    }).toString()
    await f.sharing("open", { target, id: 1, controlsQuery: query })
    assert.equal(f.opened[0], `${link.url}?${query}`)
    await f.sharing("open", { target, id: 1 })
    assert.equal(f.opened[1], link.url)
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 0)
    f.changePrototype({ canManageShareLinks: false })
    await assert.rejects(f.sharing("open", { target, id: 1, controlsQuery: query }), {
      statusCode: 403,
    })
    assert.equal(f.opened.length, 2)
  })

  it("rejects foreign destinations, unrelated parameters, duplicates and oversized control suffixes", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    await f.sharing("list", { target })
    for (const controlsQuery of [
      "https://evil.example/",
      "return_path=https://evil.example/",
      "rc.page.title=one&rc.page.title=two",
      "rc.__proto__.title=value",
      `rc.page.title=${"x".repeat(8192)}`,
      {},
    ])
      await assert.rejects(f.sharing("open", { target, id: 1, controlsQuery }), { statusCode: 422 })
    assert.deepEqual(f.opened, [])
  })

  it("opens a challenged check only on request and never replays creation", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    const authorization = {
      url: "https://replica.example/authorization/12345678-1234-1234-1234-123456789abc",
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    }
    f.respond((route, options) => {
      if (options.method === "POST")
        throw Object.assign(new Error("Verify with GitHub"), {
          statusCode: 403,
          code: "fresh_authorization_required",
          authorization,
        })
      return { id: 1, canManageShareLinks: true }
    })
    await assert.rejects(
      f.sharing("create", {
        target,
        label: "Review",
        buildNumber: 2,
        expiration: "never",
      }),
      { code: "fresh_authorization_required" },
    )
    assert.deepEqual(f.opened, [])
    assert.deepEqual(await f.sharing("authorize", { target }), {
      opened: true,
    })
    assert.deepEqual(f.opened, [authorization.url])
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
    f.changeCheckout({
      repository: "github/prototype",
      branch: "prototype/changed",
    })
    await assert.rejects(f.sharing("authorize", { target }), {
      code: "stale_share_target",
    })
    assert.equal(f.opened.length, 1)
  })

  it("opens with a read only, pins the Build, and preserves the exact create contract", async () => {
    const f = fixture()
    const context = await f.sharing("context")
    assert.equal(f.calls.length, 1)
    assert.equal(f.calls[0].method, undefined)
    assert.ok(!f.calls[0].interactive)
    assert.ok(!f.calls[0].route.includes("registration"))
    f.changePrototype({ build: { number: 3 } })
    assert.deepEqual(
      await f.sharing("create", {
        target: context.target,
        buildNumber: 2,
        label: "  Review  ",
        expiration: "never",
      }),
      link,
    )
    const create = f.calls.at(-1)
    assert.deepEqual(create.body, {
      share_link: { build_number: 2, label: "Review", expiration: "never" },
    })
    assert.equal(create.method, "POST")
    assert.equal(create.interactive, true)
    assert.deepEqual(create.expectedTarget, {
      repository: "github/prototype",
      branch: "prototype/welcome",
    })
    assert.equal(create.connectionScope.identity, "test-connection")
  })

  it("lists all Builds, opens a validated public URL, and deletes only retrieved links", async () => {
    const f = fixture()
    const context = await f.sharing("context")
    const page = await f.sharing("list", { target: context.target })
    assert.deepEqual(page.shareLinks, [listed])
    assert.deepEqual(await f.sharing("open", { target: context.target, id: 1 }), { opened: true })
    assert.deepEqual(f.opened, [link.url])
    assert.deepEqual(await f.sharing("delete", { target: context.target, id: 1 }), {
      deleted: true,
    })
    assert.equal(f.calls.at(-1).method, "DELETE")
    assert.ok(f.calls.at(-1).route.endsWith("/share_links/1"))
    await assert.rejects(f.sharing("delete", { target: context.target, id: 1 }), {
      statusCode: 404,
    })
  })

  it("does not infer share permission from write access or a latest author", async () => {
    const f = fixture()
    f.changePrototype({ canManageShareLinks: false, canEdit: true })
    const context = await f.sharing("context")
    await assert.rejects(f.sharing("list", { target: context.target }), {
      statusCode: 403,
    })
    await assert.rejects(f.sharing("create", { target: context.target }), {
      statusCode: 403,
    })
    assert.equal(f.calls.length, 1)
    f.changePrototype({ canManageShareLinks: undefined })
    const olderContext = await f.sharing("context")
    assert.equal(olderContext.prototype.id, context.prototype.id)
    await assert.rejects(f.sharing("list", { target: olderContext.target }), {
      statusCode: 403,
    })
    for (const permission of [null, "true", 1]) {
      f.changePrototype({ canManageShareLinks: permission })
      await assert.rejects(f.sharing("context"), /Update Hub/)
    }
  })

  it("validates expiry, UTF-8 byte length, Build selection, ids, and page responses", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    for (const input of [
      { buildNumber: 3, label: "Review", expiration: "never" },
      { buildNumber: 2, label: "Review", expiration: "forever" },
      { buildNumber: 2, label: " ", expiration: "never" },
      { buildNumber: 2, label: "é".repeat(51), expiration: "never" },
    ])
      await assert.rejects(f.sharing("create", { target, ...input }), {
        statusCode: 422,
      })
    await assert.rejects(f.sharing("delete", { target, id: "../1" }), {
      statusCode: 404,
    })
    f.respond(() => ({ shareLinks: [], hasMore: true, nextCursor: null }))
    await assert.rejects(f.sharing("list", { target }), /invalid share-link list/)
  })

  it("rejects foreign or credential-bearing URLs before launching a browser", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    for (const url of [
      "https://elsewhere.example/share/123",
      "https://user:secret@replica.example/share/123",
      "https://replica.example/repositories/2001",
    ]) {
      f.respond(() => ({
        shareLinks: [{ ...listed, url }],
        hasMore: false,
        nextCursor: null,
      }))
      await assert.rejects(f.sharing("list", { target }), /invalid public share URL/)
    }
    assert.deepEqual(f.opened, [])
  })

  it("rejects stale checkout and switched Hub targets before creating", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    f.changeCheckout({
      repository: "github/prototype",
      branch: "prototype/other",
    })
    await assert.rejects(
      f.sharing("create", {
        target,
        buildNumber: 2,
        label: "Review",
        expiration: "never",
      }),
      { code: "stale_share_target" },
    )
    assert.equal(f.calls.length, 1)
    const switched = fixture()
    const context = await switched.sharing("context")
    switched.hub.origin = "https://other-hub.example"
    await assert.rejects(
      switched.sharing("create", {
        target: context.target,
        buildNumber: 2,
        label: "Review",
        expiration: "never",
      }),
      { code: "stale_share_target" },
    )
    assert.equal(switched.calls.length, 1)
  })

  it("guards double dispatch and reconciles unknown outcomes without replaying creation", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    let reject
    f.respond(
      () =>
        new Promise((_, failure) => {
          reject = failure
        }),
    )
    const input = {
      target,
      buildNumber: 2,
      label: "Review",
      expiration: "seven_days",
    }
    const pending = f.sharing("create", input)
    await new Promise((resolve) => setImmediate(resolve))
    await assert.rejects(f.sharing("create", input), /already in progress/)
    reject(
      Object.assign(new Error("Timed out"), {
        deliveryPhase: "after_dispatch",
      }),
    )
    await assert.rejects(pending, { code: "share_delivery_unknown" })
    await assert.rejects(f.sharing("create", input), {
      code: "share_delivery_unknown",
    })
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
    f.respond(() => ({
      shareLinks: [listed],
      hasMore: false,
      nextCursor: null,
    }))
    await f.sharing("list", { target })
    assert.equal(f.calls.filter((call) => call.method === "POST").length, 1)
  })

  it("treats a malformed successful creation response as an unknown outcome", async () => {
    const f = fixture()
    const { target } = await f.sharing("context")
    f.respond(() => ({ ...link, buildNumber: 3 }))
    await assert.rejects(
      f.sharing("create", {
        target,
        buildNumber: 2,
        label: "Review",
        expiration: "never",
      }),
      { code: "share_delivery_unknown" },
    )
  })
})
