require "pathname"

# Keeps private application data in dedicated directories outside the public server's file tree.
module PrivateStorageRoot
  class Invalid < RuntimeError; end

  def self.validate!(root, name:, application_root:, public_root:)
    root = Pathname(root).expand_path(application_root)
    existing = root.ascend.find { _1.exist? || _1.symlink? }
    if root.ascend.any?(&:symlink?) || !existing.directory?
      raise Invalid, "#{name} must name a directory without symbolic links: #{root}"
    end

    resolved = resolve(root)
    public_directory = resolve(Pathname(public_root).expand_path)
    forbidden = [
      resolve(Pathname(application_root).expand_path),
      resolve(Pathname(application_root).join("storage").expand_path),
      public_directory
    ]
    if resolved.root? || forbidden.include?(resolved) ||
        resolved.to_s.start_with?("#{public_directory}#{File::SEPARATOR}")
      raise Invalid, "#{name} must be a dedicated directory outside the public web root: #{root}"
    end
  end

  # A not-yet-created directory still has a canonical location below its nearest existing parent.
  def self.resolve(path)
    parent = path.ascend.find { _1.exist? || _1.symlink? }
    parent.realpath.join(path.relative_path_from(parent))
  end
  private_class_method :resolve
end
