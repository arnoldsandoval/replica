export interface ReviewCommentsSubscriptionOptions {
  repositoryId: number
  prototypeId: number
  onInvalidation: () => void
}
