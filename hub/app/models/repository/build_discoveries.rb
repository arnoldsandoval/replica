# Records a branch commit as a Build and preserves known commit ordering.
class Repository::BuildDiscoveries < ActiveRecord::AssociatedObject
  # Creates or reuses a Build and skips older queued Builds identified by a push.
  # Recovery's head and observation revision share the lock used for promotion.
  def record!(branch_name:, commit_sha:, previous_commit_sha: nil, branch_head: false,
    default_branch: record.default_branch, expected_current_build_id: :any,
    expected_head_observation_revision: :any, expected_prototype_id: :any,
    resume_retired: nil, prototype_id: nil)
    build = record.with_lock do
      return if record.installation_state != "active" || !record.build_branch?(branch_name)

      owner = record.prototypes.active.find_by(branch_name:) ||
        record.prototypes.retired.where(branch_name:).order(branch_deleted_at: :desc, id: :desc).first
      unchanged_owner = expected_prototype_id == :any || owner&.id == expected_prototype_id
      # First discovery can race safely. Later histories need a saved identity.
      if !unchanged_owner && prototype_id.nil? &&
          (expected_prototype_id.present? || record.prototypes.retired.exists?(branch_name:))
        return
      end
      if !resume_retired.nil? &&
          (!unchanged_owner || owner&.head_observation_revision != expected_head_observation_revision)
        return
      end

      prototype = if prototype_id
        record.prototypes.where(branch_name:).find(prototype_id)
      elsif owner&.branch_deleted_at.present? && resume_retired == false
        record.prototypes.create!(branch_name:)
      else
        owner || record.prototypes.create!(branch_name:)
      end
      prototype.with_lock do
        if resume_retired == true
          prototype.update!(branch_deleted_at: nil, retired_head_sha: nil)
        end
        if branch_name == default_branch && !prototype.replica?
          prototype.update!(replica: true, registered_at: nil)
        end
        existing = prototype.builds.find_by(commit_sha:)
        build = if existing
          record_replaced_commit!(existing, previous_commit_sha)
          existing
        else
          create_build!(prototype, commit_sha, previous_commit_sha)
        end
        unchanged_head = expected_current_build_id == :any || prototype.current_build_id == expected_current_build_id
        unchanged_observation = expected_head_observation_revision == :any ||
          prototype.head_observation_revision == expected_head_observation_revision
        head_recorded = branch_head && unchanged_owner && unchanged_head &&
          (unchanged_observation || resume_retired == false) && prototype.branch_deleted_at.nil?
        record_branch_head!(prototype, build) if head_recorded
        yield head_recorded if block_given?
        build
      end
    end
    return if build.nil?

    build.commit_author.request! if !record.local?
    if build.prototype.reviewable? && build.start_page_checked_at.nil? && build.prototype.start_page_set_at.nil?
      build.import_start_page_later!
    end
    build
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  # Creates a Build and skips older queued Builds identified by the push.
  def create_build!(prototype, commit_sha, previous_commit_sha)
    superseded = successor_exists?(prototype, commit_sha)
    build = prototype.builds.create! \
      number: prototype.builds.maximum(:number).to_i + 1,
      commit_sha:,
      previous_commit_sha:,
      state: superseded ? "superseded" : "queued",
      finished_at: superseded ? Time.current : nil
    supersede_predecessors!(prototype, previous_commit_sha)
    build
  end

  # Records the commit replaced by a push and skips its queued Build.
  def record_replaced_commit!(build, previous_commit_sha)
    return if previous_commit_sha.nil?

    build.update!(previous_commit_sha:) if build.previous_commit_sha.nil?
    supersede_predecessors!(build.prototype, build.previous_commit_sha)
  end

  # Reports whether a newer known build names this commit as its predecessor.
  def successor_exists?(prototype, commit_sha)
    prototype.builds.exists?(previous_commit_sha: commit_sha)
  end

  # Counts repeated head observations too, so delayed recovery cannot undo them.
  def record_branch_head!(prototype, build)
    changed = prototype.current_build_id != build.id
    attributes = { head_observation_revision: prototype.head_observation_revision + 1 }
    attributes[:current_build] = build if changed
    if record.local? && (changed || prototype.local_head_observed_at.nil?)
      attributes[:local_head_observed_at] = Time.current
    end
    prototype.update!(attributes)
  end

  # Supersedes queued commits along the known predecessor chain.
  def supersede_predecessors!(prototype, commit_sha)
    seen = Set.new
    while commit_sha.present? && seen.add?(commit_sha)
      predecessor = prototype.builds.find_by(commit_sha:)
      break if predecessor.nil?

      predecessor.update!(state: "superseded", finished_at: Time.current) if predecessor.state == "queued"
      commit_sha = predecessor.previous_commit_sha
    end
  end
end
