const STRICT = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})Z$/
const LOOSE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/
const DURATION = /^(\d{1,6})([dhm])$/

/** Whether a value is a v1 timestamp: UTC, six fractional digits, and a real calendar time. */
export function isTimestamp(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/.test(value))
    return false
  const milliseconds = Date.parse(value)
  return (
    Number.isFinite(milliseconds) &&
    new Date(milliseconds).toISOString() === `${value.slice(0, 23)}Z`
  )
}

/**
 * Convert an RFC 3339 time with any offset and up to nine fractional digits to the v1 form.
 * Digits after the sixth are dropped, so the result never moves forward in time.
 *
 * @param {string} value
 * @returns {string}
 */
export function normalizeTimestamp(value) {
  const match = typeof value === "string" ? LOOSE.exec(value) : null
  const milliseconds = match ? calendarTime(match) : null
  if (milliseconds === null)
    throw new Error(`Not a valid RFC 3339 time: ${String(value).slice(0, 64)}`)
  const offset = match[8] === "Z" ? 0 : offsetMinutes(match[8])
  const fraction = (match[7] ?? "").padEnd(6, "0").slice(0, 6)
  const instant = new Date(milliseconds - offset * 60_000)
  if (instant.getUTCFullYear() < 0 || instant.getUTCFullYear() > 9999)
    throw new Error("The normalized UTC time is outside the v1 four-digit year range.")
  const utc = instant.toISOString().slice(0, 19)
  return `${utc}.${fraction}Z`
}

/** An instant, in milliseconds since the epoch, in the v1 form. */
export function timestampFromMilliseconds(milliseconds) {
  const iso = new Date(milliseconds).toISOString()
  return `${iso.slice(0, 23)}000Z`
}

/**
 * Read a time option: now, a duration before now such as 7d, 12h, or 30m, or an RFC 3339 time.
 *
 * @param {string} value
 * @param {number} nowMilliseconds
 */
export function parseTimeOption(value, nowMilliseconds) {
  if (value === "now") return timestampFromMilliseconds(nowMilliseconds)
  const duration = DURATION.exec(value)
  if (duration) {
    const unit = { d: 86_400_000, h: 3_600_000, m: 60_000 }[duration[2]]
    return timestampFromMilliseconds(nowMilliseconds - Number(duration[1]) * unit)
  }
  return normalizeTimestamp(value)
}

/** Milliseconds since the epoch for a v1 timestamp, dropping microseconds. */
export function timestampMilliseconds(value) {
  const match = STRICT.exec(value)
  const milliseconds = match ? calendarTime(match) : null
  if (milliseconds === null) throw new Error(`Not a v1 timestamp: ${value}`)
  return milliseconds + Number(match[7].slice(0, 3))
}

function calendarTime(match) {
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number)
  if (hour > 23 || minute > 59 || second > 59) return null
  const date = new Date(0)
  date.setUTCFullYear(year, month - 1, day)
  date.setUTCHours(hour, minute, second, 0)
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  )
    return null
  return date.getTime()
}

function offsetMinutes(offset) {
  const sign = offset[0] === "-" ? -1 : 1
  const hours = Number(offset.slice(1, 3))
  const minutes = Number(offset.slice(4, 6))
  if (hours > 23 || minutes > 59) throw new Error(`Not a valid time offset: ${offset}`)
  return sign * (hours * 60 + minutes)
}
