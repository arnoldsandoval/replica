---
name: browser-canvas-validation
description: "Use the Copilot browser canvas first for rendered route checks, interaction tests, screenshots and visual, responsive or accessibility evidence. Use configured isolated Playwright MCP only when the canvas is unavailable for a required check."
---

# Browser canvas validation

Canvas inspection requires a Copilot host exposing the browser canvas. It is not
a universal browser API. A repository-configured isolated Playwright MCP fallback
can cover authorized checks only when the canvas is unavailable for that check.
This policy also governs browser evidence gathered by other skills and agent
work. Existing automated suites and CI/capture drivers remain unchanged.
Default to read-only validation of the requested outcome.
A validation request does not authorize source fixes, commits, publishing or
real application mutations. Use approved test state and confirm side effects
before submissions, deletion, messages or changes to authentication.

## Required reads and dependencies

Read [context resolution](../product-design/references/context-resolution.md)
and the complete [workflow](./WORKFLOW.md) before driving a page.
Install `product-design` for the shared resolver and scenario policy.
The optional [agent-browser fallback](../agent-browser/SKILL.md) is needed only
for an explicit CLI-only request or a named requirement neither the canvas nor
configured MCP fallback can meet, not for ordinary checks.
If a required companion or sibling skill is missing, stop and name its path
before checks. Do not auto-install dependencies.

Select the first existing root, `.agents/context/`, then `.github/contexts/`.
Read `PRODUCT-DESIGN.md`, `REPOSITORY.md` and `BROWSER-VALIDATION.md`
directly there. Read `DESIGN-SYSTEM.md` for component-specific assertions.
No manifest or canvas-specific pack file is required. Never mix roots.

Missing required context stops validation. Report the selected root/file and
offer `setup-skills` to author or refresh context under the shared
resolution rules. Do not invoke it
automatically. Never read drafts as active context. Follow relevant owner links
and evidence anchors, preserve `proposed-default` labels and disclose conflicts.
Read current owner guidance on every run. Product context owns scenarios and
state policy. Browser context owns target URL, server, routes and recovery.

Use only permitted sources. Do not research remotely or broaden exclusions
during validation. Request explicit refresh if required documentation is stale
or missing. A document with gaps does not prove runtime capabilities.

## Runtime contract

Discover the available canvas types. If `browser` or the necessary canvas tools
are absent, report the missing runtime and stop this path, not a pass or a silent
backend substitution. Use the explicit configured MCP handoff in
[WORKFLOW.md](./WORKFLOW.md) if available. Call `list_canvas_capabilities` for the actual browser
type before opening or acting. Use its advertised open input and action schemas.
No frozen action list in this skill overrides the runtime.

Keep the canvas type and caller-chosen `instanceId` handle distinct.
Address the panel with that handle through `invoke_canvas_action`. If the
advertised action needs no separate page identifier, call it directly; do not
wait for a page-acquisition tool. Reuse a context-declared session handle when
appropriate. Only when an action schema requires a separate page identifier,
obtain it from runtime results or an explicit supported host contract.
If discovery and returned identifiers cannot satisfy an action schema, report
the mismatch and stop rather than inventing a value or an unavailable tool.
Missing required page acquisition may use the same explicit MCP handoff; it is not an
action failure or permission to infer IDs. A missing action can use that handoff
for the affected assertion only; keep supported checks in the canvas.

Open/reuse once, read fresh rendered structure, assert the target rendered, then
act using observed elements and advertised actions. Re-read after DOM changes,
navigation or reload before using refs. Do not assume a click returns a snapshot
or that scoped reads/batching exist. Details and recovery are in
[WORKFLOW.md](./WORKFLOW.md).

## Output

Report target, context document paths, runtime, tested state/flow, assertions and evidence.
Separate confirmed failures from unavailable or untested assertions. An overall
pass requires every applicable requested assertion to be verified. No render,
missing evidence or unavailable runtime means failed or incomplete validation.
Static checks do not prove live browser behavior. Do not automatically run
broader design, accessibility, responsive or cross-browser audits.
