require "open3"

# Reads committed branch heads from configured local repositories.
class Repository::LocalDiscovery < ActiveRecord::AssociatedObject
  # Runs Git without a shell and reports failures instead of showing stale results.
  def self.git!(*arguments)
    output, error, status = Open3.capture3("git", *arguments)
    raise LocalDevelopment::Error, "Git failed: #{error.strip.presence || arguments.join(" ")}" if !status.success?

    output.strip
  end

  # Discovers configured repositories without recording any branch Builds.
  def self.register_repositories!(on_error: nil)
    raise LocalDevelopment::Error, "Local mode is disabled" if !LocalDevelopment.enabled?

    paths = LocalDevelopment.repository_paths
    paths.each do |path|
      begin
        actual = git!("-C", path.to_s, "rev-parse", "--show-toplevel")
        raise LocalDevelopment::Error, "Not a standalone repository: #{path}" if actual != path.to_s

        branch_sha = git!("-C", path.to_s, "for-each-ref",
          "--count=1", "--format=%(objectname)", "refs/heads")
        if branch_sha.blank?
          raise LocalDevelopment::Error,
            I18n.t("local_development.commit_required", repository: path)
        end

        identity = LocalDevelopment.repository_identity(path, create: true)
        default_branch = default_branch_for(path)
        Repository.transaction do
          repository = Repository.find_by(local_path: path.to_s, local_identity: identity) ||
            Repository.find_by(local_path: path.to_s, local_identity: nil) ||
            Repository.new(local_path: path.to_s, local_identity: identity)
          Repository.active.where(local_path: path.to_s).where.not(id: repository.id).find_each do |stale|
            stale.update!(installation_state: "removed", removed_at: Time.current)
          end
          repository.assign_attributes \
            local_identity: identity,
            name_with_owner: "local/#{path.basename}",
            default_branch: repository.persisted? ? repository.default_branch : default_branch,
            installation_state: "active",
            removed_at: nil,
            synchronized_at: Time.current
          repository.save!
        end
      rescue LocalDevelopment::Error => error
        raise if on_error.nil?

        on_error.call(path, error)
      end
    end

    Repository.active.where(github_id: nil).where.not(local_path: paths.map(&:to_s)).find_each do |repository|
      repository.update!(installation_state: "removed", removed_at: Time.current)
    end
  end

  # Scans local repositories without rewriting their registration on every tick.
  def self.refresh_all!
    raise LocalDevelopment::Error, "Local mode is disabled" if !LocalDevelopment.enabled?

    paths = LocalDevelopment.repository_paths.map(&:to_s).sort
    registered = Repository.active.where(github_id: nil).to_a
    changed = registered.any? do |repository|
      !LocalDevelopment.repository_available?(repository.local_path, identity: repository.local_identity)
    rescue LocalDevelopment::Error => error
      report_error(repository.local_path, error)
      true
    end
    if paths != registered.map(&:local_path).sort || changed
      register_repositories!(on_error: method(:report_error))
    end

    Repository.active.where(github_id: nil).find_each do |repository|
      repository.local_discovery.refresh!
    rescue LocalDevelopment::Error => error
      report_error(repository.local_path, error)
    end
  end

  # Reports a broken checkout without blocking healthy repositories.
  def self.report_error(path, error)
    Rails.logger.error("Could not discover local repository #{path}: #{error.full_message}")
  end

  # Prefers the repository's conventional base even when a prototype is checked out.
  def self.default_branch_for(path, allow_detached: false)
    %w[main master].each do |branch|
      return branch if system("git", "-C", path.to_s, "show-ref", "--verify", "--quiet",
        "refs/heads/#{branch}", out: File::NULL, err: File::NULL)
    end
    branch = git!("-C", path.to_s, "branch", "--show-current")
    return branch if branch.present?
    return if allow_detached

    raise LocalDevelopment::Error, "Check out a default branch before registering local repository: #{path}"
  end

  # Records changed heads; an explicit refresh may retry a queued Build.
  def refresh!(requeue_pending: false)
    raise LocalDevelopment::Error, "Local mode is disabled" if !LocalDevelopment.enabled? || !record.local?

    path = Pathname(record.local_path)
    if !LocalDevelopment.repository_available?(record.local_path, identity: record.local_identity)
      raise LocalDevelopment::Error, "Local repository is no longer configured: #{path}"
    end

    refs = self.class.git!("-C", path.to_s, "for-each-ref",
      "--format=%(refname:short) %(objectname)", "refs/heads")
    heads = refs.each_line.filter_map do |line|
      branch, sha = line.strip.split(" ", 2)
      [ branch, sha ] if record.build_branch?(branch)
    end.to_h
    if !heads.key?(record.default_branch)
      replacement = self.class.default_branch_for(path, allow_detached: true)
      record.with_lock do
        next if heads.key?(record.default_branch) || !heads.key?(replacement) ||
          record.reviewable_prototypes.exists?(branch_name: replacement)

        record.update!(default_branch: replacement)
      end
    end
    prototypes = record.prototypes.where(branch_name: heads.keys)
      .includes(:current_build).index_by(&:branch_name)
    heads.each do |branch, sha|
      current = prototypes[branch]&.current_build
      if prototypes[branch]&.reviewable? && current&.commit_sha == sha && current.start_page_checked_at.nil? &&
          prototypes[branch].start_page_set_at.nil?
        current.import_start_page_later!
      end
      next if current&.commit_sha == sha && prototypes[branch].local_head_observed_at.present? &&
        (!requeue_pending || current.state != "queued")

      build = record.build_discoveries.record!(branch_name: branch, commit_sha: sha, branch_head: true)
      if build && build.commit_author_checked_at.nil?
        author = self.class.git!("-C", path.to_s, "show", "-s", "--format=%an", sha)
        if author.present? && author.bytesize <= 255
          build.update!(commit_author_name: author, commit_author_checked_at: Time.current)
        end
      end
      build.build_local_package_later! if build&.state == "queued"
    end
    record.update!(synchronized_at: Time.current)
  end
end
