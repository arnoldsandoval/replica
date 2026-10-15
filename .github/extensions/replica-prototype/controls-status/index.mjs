import { plainText } from "../validate-controls/index.mjs"

const STATUSES = new Set([
  "pending",
  "ready",
  "no-controls",
  "missing-runtime",
  "unsupported-runtime",
  "invalid-config",
])

function text(value, limit) {
  return typeof value === "string" && value.length <= limit
}

/** Projects runtime diagnostics without forwarding definitions, values or app callback results. */
export function projectControlsStatus(value, prototypeUrl) {
  const url = typeof value?.url === "string" ? URL.parse(value.url) : null
  if (
    !url ||
    (prototypeUrl && url.origin !== new URL(prototypeUrl).origin) ||
    url.username ||
    url.password ||
    !text(value.url, 16_384) ||
    !STATUSES.has(value.status) ||
    !text(value.error, 1000) ||
    !Array.isArray(value.controls) ||
    value.controls.length > 10_000 ||
    (value.status === "pending" && value.controls.length)
  )
    throw new Error("The live canvas returned invalid Controls status.")
  const controls = projectControls(value.controls)
  let runtime
  if (value.runtime !== undefined) {
    if (
      !value.runtime ||
      typeof value.runtime !== "object" ||
      !STATUSES.has(value.runtime.status) ||
      !text(value.runtime.error, 1000) ||
      !Array.isArray(value.runtime.controls) ||
      value.runtime.controls.length > 10_000 ||
      (value.runtime.status === "pending" && value.runtime.controls.length)
    )
      throw new Error("The live canvas returned invalid runtime Controls diagnostics.")
    runtime = {
      status: value.runtime.status,
      error: plainText(value.runtime.error, 1000),
      controls: projectControls(value.runtime.controls),
    }
  }
  return {
    status: value.status,
    url: url.href,
    origin: url.origin,
    route: { pathname: url.pathname, search: url.search, hash: url.hash },
    error: plainText(value.error, 1000),
    controls,
    ...(runtime ? { runtime } : {}),
  }
}

function projectControls(controls) {
  return controls.map((control) => {
    if (
      !text(control?.scope, 64) ||
      !text(control.id, 64) ||
      typeof control.available !== "boolean" ||
      typeof control.busy !== "boolean" ||
      typeof control.visible !== "boolean" ||
      !text(control.error, 500)
    )
      throw new Error("The live canvas returned invalid control diagnostics.")
    return {
      scope: control.scope,
      id: control.id,
      available: control.available,
      busy: control.busy,
      visible: control.visible,
      error: plainText(control.error, 500),
    }
  })
}
