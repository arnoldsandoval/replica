export function createConsolidator(options, { createRecurrenceConsolidator }) {
  const recurrence = createRecurrenceConsolidator(options)
  return {
    ...recurrence,
    async consolidate(request, view) {
      const result = await recurrence.consolidate(request, view)
      return {
        ...result,
        proposals: result.proposals.map((proposal) => {
          const withoutSupport = { ...proposal }
          delete withoutSupport.support
          return withoutSupport
        }),
      }
    },
  }
}
