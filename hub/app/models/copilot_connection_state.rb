# == Schema Information
#
# Table name: copilot_connection_states
# Database name: primary
#
#  id            :integer          not null, primary key
#  generation    :bigint           default(0), not null
#  singleton_key :integer          default(1), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_copilot_connection_states_on_singleton_key  (singleton_key) UNIQUE
#
# Check Constraints
#
#  copilot_connection_states_generation  (generation >= 0)
#  copilot_connection_states_singleton   (singleton_key = 1)
#
# Keeps the lifecycle counter even while Copilot is disconnected, so an earlier initial check
# cannot miss an intervening connect followed by a disconnect.
class CopilotConnectionState < ApplicationRecord
  attr_readonly :singleton_key
  validates :singleton_key, inclusion: { in: [ 1 ] }
  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Reads the persistent lifecycle state without reusing a request's cached result.
  def self.current
    uncached { find_or_create_by!(singleton_key: 1) }
  end

  # Advances within the caller's connection-change transaction.
  def self.advance!
    current.increment!(:generation)
  end
end
