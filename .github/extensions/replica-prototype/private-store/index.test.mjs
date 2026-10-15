import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdir, rm, utimes, writeFile } from "node:fs/promises"
import path from "node:path"
import { promisify } from "node:util"
import { it } from "node:test"

import { createPrivateStore } from "./index.mjs"

it("serializes separate processes and recovers a process that died holding the lock", async () => {
  const directory = path.join(process.cwd(), "storage/replica-extension-tests", randomUUID())
  await mkdir(directory, { recursive: true, mode: 0o700 })
  const store = createPrivateStore(directory)
  const script = `
    import { createPrivateStore } from ${JSON.stringify(new URL("./index.mjs", import.meta.url).href)};
    const store = createPrivateStore(${JSON.stringify(directory)});
    await store.lock("counter", async () => {
      const count = await store.read("counter") || 0;
      await new Promise(resolve => setTimeout(resolve, 20));
      await store.write("counter", count + 1);
    });
  `
  try {
    await Promise.all(
      Array.from({ length: 6 }, () =>
        promisify(execFile)(process.execPath, ["--input-type=module", "-e", script]),
      ),
    )
    assert.equal(await store.read("counter"), 6)
    await promisify(execFile)(process.execPath, [
      "--input-type=module",
      "-e",
      `import { createPrivateStore } from ${JSON.stringify(new URL("./index.mjs", import.meta.url).href)};
       await createPrivateStore(${JSON.stringify(directory)}).lock("counter", () => process.exit(0));`,
    ])
    await store.lock("counter", () => store.write("counter", 7))
    assert.equal(await store.read("counter"), 7)
    await mkdir(path.join(directory, "counter.lock"))
    await writeFile(path.join(directory, "counter.lock/owner"), "")
    await mkdir(path.join(directory, "counter.lock/reaper"))
    const old = new Date(Date.now() - 120_000)
    await utimes(path.join(directory, "counter.lock"), old, old)
    await utimes(path.join(directory, "counter.lock/owner"), old, old)
    await utimes(path.join(directory, "counter.lock/reaper"), old, old)
    await store.lock("counter", () => store.write("counter", 8))
    assert.equal(await store.read("counter"), 8)
    await writeFile(path.join(directory, "public"), "{}", { mode: 0o644 })
    await assert.rejects(store.read("public"), /not private/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})
