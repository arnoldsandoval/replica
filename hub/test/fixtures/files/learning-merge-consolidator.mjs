export function createConsolidator() {
  return {
    manifest: { id: "test-merge", version: "1.0.0" },
    async consolidate(_request, view) {
      const targets = view.memories
        .filter((memory) => memory.state === "accepted" && memory.effective)
        .slice(0, 2)
      if (targets.length < 2) return { proposals: [], diagnostics: [] }
      return {
        proposals: [
          {
            schemaVersion: "replica.memory-proposal/v1",
            kind: "rule",
            themeKey: "merged-form-guidance",
            content: "Use visible form labels and readable text together.",
            evidence: targets.flatMap((memory) => memory.evidence),
            rationale: {
              recurrence: "Two accepted learnings cover related form problems.",
              expectedBenefit: "Keep the guidance together.",
              falsification: "Revisit if reviewers disagree with the combined guidance.",
            },
            lifecycle: { action: "merge", targets: targets.map((memory) => memory.id) },
            consolidator: { id: "test-merge", version: "1.0.0" },
          },
        ],
        diagnostics: [],
      }
    },
  }
}
