import type * as Superglue from "@thoughtbot/superglue"
import { act } from "react"
import { describe, expect, it, vi } from "vitest"

import { mountApplication } from "."

vi.mock("@thoughtbot/superglue", async (importOriginal) => {
  const original = await importOriginal<typeof Superglue>()

  return { ...original, Application: () => <div>Replica Hub</div> }
})

describe("mountApplication()", () => {
  it("follows the user's system light or dark preference", () => {
    document.body.innerHTML = '<div id="app"></div>'

    act(() => mountApplication())

    expect(document.querySelector(".hub-theme")).toHaveAttribute("data-color-mode", "light")
  })
})
