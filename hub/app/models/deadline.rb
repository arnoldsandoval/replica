# A time limit that several steps share, so their own limits add up to one budget. It reads the
# monotonic clock, so a change to the system clock cannot stretch or cut it.
class Deadline
  # Starts a deadline the given number of seconds from now.
  def initialize(seconds)
    @at = self.class.now + seconds.to_f
  end

  # Seconds left before the deadline, never less than zero.
  def remaining
    [ @at - self.class.now, 0.0 ].max
  end

  # The monotonic clock's current reading, in seconds.
  def self.now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
