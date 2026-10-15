import assert from "node:assert/strict"
import { describe, it } from "node:test"

import {
  createStartupStatus,
  DESCRIPTION_ERROR,
  publicStartupError,
  publicStartupStatus,
  STARTUP_ERROR,
  StartupError,
} from "./index.mjs"

describe("startup error filtering", () => {
  it("exposes only explicitly intentional errors", () => {
    assert.equal(publicStartupError(new StartupError("npm is unavailable.")), "npm is unavailable.")
    for (const error of [new Error("secret=DO_NOT_EXPOSE"), "secret=DO_NOT_EXPOSE", null]) {
      assert.equal(publicStartupError(error), STARTUP_ERROR)
      assert.equal(publicStartupError(error, DESCRIPTION_ERROR), DESCRIPTION_ERROR)
    }
  })

  it("projects filtered manager status without exposing extra fields", () => {
    const status = createStartupStatus({
      starting: true,
      message: "Starting npm run dev...",
      output: "Intentional script output",
      details: "secret=DO_NOT_EXPOSE",
    })
    assert.deepEqual(publicStartupStatus(status), {
      starting: true,
      message: "Starting npm run dev...",
      output: "Intentional script output",
    })
    assert.equal(publicStartupStatus({ ...status }).message, STARTUP_ERROR)
  })

  it("keeps intentional script output independent of raw exception filtering", () => {
    assert.deepEqual(
      publicStartupStatus({
        starting: false,
        message: "secret=DO_NOT_EXPOSE",
        output: "Intentional script output",
      }),
      {
        starting: false,
        message: STARTUP_ERROR,
        output: "Intentional script output",
      },
    )
    assert.deepEqual(publicStartupStatus({ message: "" }), {
      starting: false,
      message: "",
      output: "",
    })
  })
})
