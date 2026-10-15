import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { createServer, request } from "node:http"
import { gzipSync } from "node:zlib"
import { it } from "node:test"

import { startPreviewProxy } from "./index.mjs"

async function fixture(t, handler) {
  const upstream = createServer(handler)
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve))
  const prototypeUrl = `http://127.0.0.1:${upstream.address().port}/nested?view=grid#section`
  const parentOrigin = "http://127.0.0.1:4321"
  const proxy = await startPreviewProxy({
    prototypeUrl,
    parentOrigin,
    source: "export function installBridge() {}",
  })
  t.after(async () => {
    await proxy.close()
    await new Promise((resolve) => upstream.close(resolve))
  })
  return { upstream, proxy, prototypeUrl, parentOrigin }
}

it("adds one bridge to compressed HTML while retaining policy, paths and binary assets", async (t) => {
  const received = []
  const { proxy, prototypeUrl } = await fixture(t, (request, response) => {
    received.push({ url: request.url, headers: request.headers })
    if (request.url === "/image") {
      response.writeHead(200, { "Content-Type": "image/png", ETag: "image-version" })
      response.end(Buffer.from([0, 1, 255]))
    } else {
      response.writeHead(200, {
        "Content-Type": "text/html; charset=utf-8",
        "Content-Encoding": "gzip",
        "Content-Security-Policy": "script-src 'self'; frame-ancestors 'self'",
        "X-Frame-Options": "SAMEORIGIN",
        ETag: "html-version",
      })
      response.end(gzipSync("<!doctype html><body><h1>Prototype</h1></body>"))
    }
  })
  const page = await fetch(proxy.url)
  const html = await page.text()
  assert.match(html, /<h1>Prototype<\/h1>/)
  assert.match(html, /data-replica-canvas="1"/)
  assert.equal(page.headers.get("content-encoding"), null)
  assert.equal(page.headers.get("etag"), null)
  assert.equal(
    page.headers.get("content-security-policy"),
    "script-src 'self'; frame-ancestors 'self'",
  )
  assert.equal(page.headers.get("x-frame-options"), "SAMEORIGIN")
  assert.equal(page.headers.get("cache-control"), "no-store")
  assert.equal(received[0].url, "/nested?view=grid")
  assert.equal(received[0].headers.host, new URL(prototypeUrl).host)
  const image = await fetch(new URL("/image", proxy.url))
  assert.deepEqual(Buffer.from(await image.arrayBuffer()), Buffer.from([0, 1, 255]))
  assert.equal(image.headers.get("etag"), "image-version")
})

it("serves the same loader for configured prototypes", async (t) => {
  const { proxy, parentOrigin } = await fixture(t, (_request, response) => {
    response.setHeader("Content-Type", "text/html")
    response.end(
      '<body><script type="module" data-replica-canvas="1" src="/__replica/canvas/loader.js"></script></body>',
    )
  })
  const html = await (await fetch(proxy.url)).text()
  assert.equal(html.match(/src="\/__replica\/canvas\/loader.js"/g).length, 2)
  const loader = await (await fetch(new URL("/__replica/canvas/loader.js", proxy.url))).text()
  assert.ok(loader.includes(parentOrigin))
  assert.match(loader, /installBridge/)
  assert.equal(
    (
      await fetch(
        new URL(
          `/__replica/canvas/runtime.js?parent=${encodeURIComponent(parentOrigin)}`,
          proxy.url,
        ),
      )
    ).status,
    200,
  )
  assert.equal(
    (await fetch(new URL("/__replica/canvas/runtime.js?parent=http://127.0.0.1:1111", proxy.url)))
      .status,
    403,
  )
})

it("loads the bridge when the marker appears only in page text", async (t) => {
  const { proxy } = await fixture(t, (_request, response) => {
    response.setHeader("Content-Type", "text/html")
    response.end('<pre>&lt;script data-replica-canvas="1"&gt;&lt;/script&gt;</pre>')
  })
  const html = await (await fetch(proxy.url)).text()
  assert.match(
    html,
    /<script type="module" data-replica-canvas="1" src="\/__replica\/canvas\/loader.js"><\/script>/,
  )
})

it("forwards app requests and local redirects without sending cookies or canvas capabilities", async (t) => {
  let received
  const { proxy, prototypeUrl, parentOrigin } = await fixture(t, async (request, response) => {
    if (request.url === "/redirect") {
      response.writeHead(302, { Location: "/next?q=1#section" })
      response.end()
      return
    }
    let body = ""
    for await (const chunk of request) body += chunk
    received = { headers: request.headers, body, method: request.method }
    response.setHeader("Content-Type", "application/json")
    response.end("{}")
  })
  const origin = new URL(proxy.url).origin
  const response = await fetch(proxy.url, {
    method: "POST",
    headers: {
      Origin: origin,
      Referer: `${parentOrigin}/?document=private-document`,
      Cookie: "hub-credential=private",
      "X-Replica-Canvas-Token": "private-action",
      "X-Forwarded-Host": "untrusted",
      "Content-Type": "application/json",
    },
    body: '{"count":4}',
  })
  assert.equal(response.status, 200)
  assert.equal(received.method, "POST")
  assert.equal(received.body, '{"count":4}')
  assert.equal(received.headers.origin, new URL(prototypeUrl).origin)
  for (const name of ["cookie", "referer", "x-replica-canvas-token", "x-forwarded-host"])
    assert.equal(received.headers[name], undefined)
  const redirect = await fetch(new URL("/redirect", proxy.url), { redirect: "manual" })
  assert.equal(redirect.headers.get("location"), `${origin}/next?q=1#section`)
})

it("rejects remote targets, wrong origins, credentials and redirects outside the prototype", async (t) => {
  let count = 0
  const { proxy } = await fixture(t, (request, response) => {
    count++
    if (request.url === "/external") response.writeHead(302, { Location: "https://example.com/" })
    else if (request.url === "/auth") response.writeHead(200, { "Set-Cookie": "session=private" })
    response.end("not forwarded")
  })
  for (const headers of [{ Origin: "http://127.0.0.1:9999" }, { Authorization: "Bearer private" }])
    assert.equal((await fetch(proxy.url, { headers })).status, 403)
  const wrongHost = await new Promise((resolve, reject) => {
    const target = request(proxy.url, { headers: { Host: "attacker.example" } }, (response) => {
      response.resume()
      response.on("end", () => resolve(response.statusCode))
    })
    target.on("error", reject)
    target.end()
  })
  assert.equal(wrongHost, 403)
  assert.equal(count, 0)
  for (const route of ["/external", "/auth"]) {
    const response = await fetch(new URL(route, proxy.url), { redirect: "manual" })
    assert.equal(response.status, 502)
    assert.equal(response.headers.get("location"), null)
    assert.equal(response.headers.get("set-cookie"), null)
  }
  for (const prototypeUrl of ["http://example.com/", "http://user:pass@127.0.0.1:1234/"]) {
    await assert.rejects(
      startPreviewProxy({ prototypeUrl, parentOrigin: "http://127.0.0.1:4321", source: "" }),
      /unauthenticated loopback/,
    )
  }
})

it("rejects cross-site scripts without Origin before forwarding and keeps local requests usable", async (t) => {
  const received = []
  const script = "window.prototypeReady = true;"
  const { proxy } = await fixture(t, (request, response) => {
    received.push(request.url)
    response.setHeader("Content-Type", "application/javascript")
    response.end(script)
  })
  const url = new URL("/script.js", proxy.url)
  const blocked = await new Promise((resolve, reject) => {
    const target = request(
      url,
      {
        headers: {
          "Sec-Fetch-Site": "cross-site",
          "Sec-Fetch-Mode": "no-cors",
          "Sec-Fetch-Dest": "script",
        },
      },
      (response) => {
        response.resume()
        response.on("end", () => resolve(response.statusCode))
      },
    )
    target.on("error", reject)
    target.end()
  })
  assert.equal(blocked, 403)
  assert.deepEqual(received, [])
  for (const site of [undefined, "none", "same-site", "same-origin"]) {
    const allowed = await fetch(url, {
      headers: {
        "Sec-Fetch-Mode": "no-cors",
        "Sec-Fetch-Dest": "script",
        ...(site ? { "Sec-Fetch-Site": site } : {}),
      },
    })
    assert.equal(allowed.status, 200)
    assert.equal(await allowed.text(), script)
  }
  assert.equal(received.length, 4)
})

it("streams responses before they finish", async (t) => {
  let finish
  const { proxy } = await fixture(t, (_request, response) => {
    response.writeHead(200, { "Content-Type": "text/event-stream" })
    response.write("data: first\n\n")
    finish = () => response.end("data: last\n\n")
  })
  const response = await fetch(proxy.url)
  const reader = response.body.getReader()
  assert.equal(new TextDecoder().decode((await reader.read()).value), "data: first\n\n")
  finish()
  assert.equal(new TextDecoder().decode((await reader.read()).value), "data: last\n\n")
  assert.equal((await reader.read()).done, true)
})

it(
  "returns an explicit error when a partial HTML response stalls",
  { timeout: 45_000 },
  async (t) => {
    let closed
    const upstreamClosed = new Promise((resolve) => {
      closed = resolve
    })
    const { proxy } = await fixture(t, (_request, response) => {
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" })
      response.write("<body>Unfinished prototype")
      response.once("close", closed)
    })
    const response = await fetch(proxy.url)
    assert.equal(response.status, 502)
    assert.equal(await response.text(), "Replica preview: The prototype server timed out.")
    await upstreamClosed
  },
)

it("connects localhost when the prototype listens only on IPv4", async (t) => {
  const { prototypeUrl, parentOrigin } = await fixture(t, (_request, response) => {
    response.end("connected")
  })
  const url = new URL(prototypeUrl)
  url.hostname = "localhost"
  const proxy = await startPreviewProxy({ prototypeUrl: url.href, parentOrigin, source: "" })
  t.after(() => proxy.close())
  assert.equal(await (await fetch(proxy.url)).text(), "connected")
})

it("relays origin-checked WebSockets and closes its tunnels without stopping the upstream", async (t) => {
  const { proxy, upstream, prototypeUrl } = await fixture(t, (_request, response) => {
    response.end("still running")
  })
  let upgradeHeaders
  upstream.on("upgrade", (request, socket) => {
    upgradeHeaders = request.headers
    const accept = createHash("sha1")
      .update(`${request.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64")
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`,
    )
    socket.on("data", () => {})
    socket.on("end", () => socket.end())
  })
  const socket = await new Promise((resolve, reject) => {
    const target = request(new URL("/hmr?token=server-token", proxy.url), {
      headers: {
        Origin: new URL(proxy.url).origin,
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
      },
    })
    target.on("upgrade", (_response, socket) => resolve(socket))
    target.on("error", reject)
    target.end()
  })
  assert.equal(upgradeHeaders.origin, new URL(prototypeUrl).origin)
  const closed = new Promise((resolve) => socket.once("close", resolve))
  socket.resume()
  await proxy.close()
  await closed
  assert.equal(await (await fetch(prototypeUrl)).text(), "still running")
})

it(
  "keeps the preview connected after a WebSocket handshake is aborted",
  { timeout: 5000 },
  async (t) => {
    const { proxy, upstream } = await fixture(t, (_request, response) => {
      response.end("still running")
    })
    const client = request(new URL("/hmr", proxy.url), {
      headers: {
        Origin: new URL(proxy.url).origin,
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
      },
    })
    t.after(() => client.destroy())
    const aborted = new Promise((resolve) => {
      upstream.once("upgrade", (_request, socket) => {
        t.after(() => socket.destroy())
        socket.on("error", () => socket.destroy())
        socket.once("end", () => socket.end())
        socket.once("close", resolve)
        socket.resume()
        client.socket.resetAndDestroy()
      })
    })
    client.on("error", (error) => assert.equal(error.code, "ECONNRESET"))
    client.end()
    await aborted
    assert.equal(await (await fetch(proxy.url)).text(), "still running")
  },
)
