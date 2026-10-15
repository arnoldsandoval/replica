// Labels Hub's test comments in place of Copilot, so Hub's tests run the real replica-learning
// command without a network. A comment that mentions a label gets one accessibility theme, one
// that mentions contrast gets another, and each request reports a fixed usage.
export function createLabeler() {
  return {
    manifest: {
      id: "test-labeler",
      name: "Test labeler",
      version: "1.0.0",
      model: "test-model",
      externalCalls: [],
    },

    async label({ threads }) {
      const labels = threads
        .flatMap((thread) => thread.comments)
        .filter((comment) => comment.label && /label|contrast/i.test(comment.text))
        .map((comment) => ({
          comment: comment.id,
          theme: /label/i.test(comment.text)
            ? {
                key: "visible-form-labels",
                statement: "Show a visible label above every form field.",
              }
            : { key: "readable-contrast", statement: "Give text enough contrast to read." },
          signal: "accessibility",
          observation: "observed",
          stance: /disagree/i.test(comment.text) ? "contradicts" : "supports",
        }))
      return {
        labels,
        usage: [{ model: "test-model", inputTokens: 120, outputTokens: 30, nanoAiu: 5_000_000 }],
      }
    },
  }
}
