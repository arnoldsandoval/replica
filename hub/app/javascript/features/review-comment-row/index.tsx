import { Label } from "@primer/react-brand"

import { HubUserAvatar } from "@components/hub-user-avatar"
import { ReviewRelativeTime } from "@features/review-relative-time"

import type { ReviewCommentRowProps } from "./types"

import "./styles.css"

/** Uses a native button so long comments do not overlap the author or status. */
export function ReviewCommentRow({
  thread,
  currentBuildNumber,
  resolution,
  anchorStatusLabel,
  selected,
  selectionBlocked,
  copy,
  onSelect,
  buildHref,
}: ReviewCommentRowProps) {
  const { root } = thread
  const author = root.author.name || `@${root.author.login}`
  const buildLabel = copy.buildLabel.replace("%{number}", root.buildNumber.toString())
  const showBuildLink = root.buildNumber !== currentBuildNumber
  const replyCountLabel =
    thread.replies.length === 1
      ? copy.replyCountOneLabel
      : copy.replyCountOtherLabel.replace("%{count}", thread.replies.length.toString())
  let statusLabel: string | null = copy.missingAnchorLabel
  if (root.resolvedAt) {
    statusLabel = copy.resolvedLabel
  } else if (anchorStatusLabel !== undefined) {
    statusLabel = anchorStatusLabel
  } else if (!resolution) {
    statusLabel = copy.checkingAnchorLabel
  } else if (resolution.status === "resolved") {
    statusLabel = null
  } else if (resolution.status === "moved") {
    statusLabel = copy.movedAnchorLabel
  } else if (resolution.status === "changed") {
    statusLabel = copy.changedAnchorLabel
  } else if (resolution.status === "route-mismatch") {
    statusLabel = copy.routeMismatchLabel
  }

  return (
    <article className={`review-comment-row${selected ? " review-comment-row--selected" : ""}`}>
      <button
        type="button"
        className="review-comment-row__button"
        aria-pressed={selected}
        disabled={selectionBlocked && !selected}
        title={selectionBlocked && !selected ? copy.selectionBlockedLabel : undefined}
        onClick={() => onSelect(thread)}
      >
        {thread.unread ? (
          <span
            role="img"
            aria-label={copy.unreadLabel}
            title={copy.unreadLabel}
            className="review-comment-row__unread"
          />
        ) : null}

        <span className="review-comment-row__layout">
          <HubUserAvatar
            src={root.author.avatarUrl}
            size={28}
            className="review-comment-row__avatar"
          />

          <span className="review-comment-row__content">
            <span className="review-comment-row__copy">
              <span className="review-comment-row__metadata">
                <strong className="review-comment-row__author">{author}</strong>

                <ReviewRelativeTime value={thread.lastActivityAt} />
              </span>

              <span className="review-comment-row__body">
                {root.body ?? copy.deletedCommentLabel}
              </span>
            </span>
          </span>
        </span>
      </button>

      {showBuildLink || statusLabel || thread.replies.length > 0 ? (
        <span className="review-comment-row__context">
          {showBuildLink ? (
            <span className="review-comment-row__build">
              <a
                href={buildHref || root.buildPath}
                target={buildHref ? "_blank" : undefined}
                rel={buildHref ? "noopener noreferrer" : undefined}
              >
                {buildLabel}
              </a>
            </span>
          ) : (
            <span className="review-comment-row__build" />
          )}

          {thread.replies.length > 0 ? (
            <span className="review-comment-row__replies">{replyCountLabel}</span>
          ) : null}

          {statusLabel ? (
            <Label size="small" className="review-comment-row__status">
              {statusLabel}
            </Label>
          ) : null}
        </span>
      ) : null}
    </article>
  )
}
