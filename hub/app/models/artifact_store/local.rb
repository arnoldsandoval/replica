require "fileutils"
require "tempfile"

# Stores retained Build files beneath one persistent local directory.
class ArtifactStore::Local
  BUFFER_BYTES = 64.kilobytes

  # Uses root for local storage and rejects files or symbolic links in its path.
  def initialize(root:)
    @root = Pathname(root).expand_path
    existing = @root.ascend.find { _1.exist? || _1.symlink? }
    if @root.ascend.any?(&:symlink?) || !existing.directory?
      raise ArtifactStore::InvalidObject, "Local artifact root must be a directory without symbolic links: #{@root}"
    end
  end

  # Writes source without replacing name and returns the number of bytes written.
  def write(name, source:)
    directory = object_directory(name)
    prepare_directory(directory)
    Tempfile.create([ "object-", ".tmp" ], temporary_directory, binmode: true) do |temporary|
      bytes = stream(source, temporary)
      temporary.flush
      temporary.fsync
      object = directory.join(ArtifactStore::INTERNAL_SEGMENT)
      File.link(temporary.path, object)
      sync_directory(directory, rollback: object)
      bytes
    rescue Errno::EEXIST
      raise ArtifactStore::AlreadyExists, "Artifact object already exists: #{name}"
    end
  end

  # Waits for the new file name to reach disk and removes it if that fails.
  def sync_directory(directory, rollback:)
    fsync_directory(directory)
  rescue StandardError
    File.unlink(rollback) if rollback.exist?
    raise
  end

  # Ensures a directory change reaches disk before returning.
  def fsync_directory(directory)
    File.open(directory, File::RDONLY, &:fsync)
  end

  # Copies name into destination and returns the number of bytes written.
  def read(name, destination:)
    File.open(readable_object(name), "rb") do |source|
      bytes = stream(source, destination)
      destination.flush if destination.respond_to?(:flush)
      bytes
    end
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise ArtifactStore::Missing, "Artifact object does not exist: #{name}"
  end

  # Reports whether the exact stored file exists without following symbolic links.
  def exist?(name)
    object = object_file(name)
    return false if !object.exist? && !object.symlink?

    regular_file?(object, name)
  rescue Errno::ENOENT, Errno::ENOTDIR
    false
  end

  # Returns sorted stored file names equal to or below one path.
  def list(prefix)
    directory = object_directory(prefix)
    return [] if !directory.exist? && !directory.symlink?

    collect_objects(directory, prefix).sort
  rescue Errno::ENOENT, Errno::ENOTDIR
    []
  end

  # Deletes the named file and every file below it; reports whether any existed.
  def delete_prefix(prefix)
    directory = object_directory(prefix)
    return false if !directory.exist? && !directory.symlink?

    reject_link(directory, prefix)
    FileUtils.remove_entry(directory)
    fsync_directory(directory.dirname)
    true
  rescue Errno::ENOENT, Errno::ENOTDIR
    false
  end

  private

  attr_reader :root

  # Finds the directory for name without following symbolic links.
  def object_directory(name)
    reject_link(root, root.to_s)
    name.split("/").reduce(root) do |parent, segment|
      path = parent.join(segment)
      reject_link(path, path.relative_path_from(root).to_s) if path.exist? || path.symlink?
      path
    end
  end

  # Returns the file that stores one object's contents.
  def object_file(name)
    object_directory(name).join(ArtifactStore::INTERNAL_SEGMENT)
  end

  # Creates missing path directories without following symbolic links.
  def prepare_directory(directory)
    prepare_root
    relative = directory.relative_path_from(root)
    relative.each_filename.reduce(root) do |parent, segment|
      child = parent.join(segment)
      create_directory(parent, child) if !child.exist? && !child.symlink?
      reject_link(child, child.relative_path_from(root).to_s)
      if !child.directory?
        raise ArtifactStore::InvalidObject, "Local artifact storage path must be a directory: #{child.relative_path_from(root)}"
      end
      child
    rescue Errno::EEXIST
      retry
    end
  end

  # Creates the storage directory and any missing parent directories.
  def prepare_root
    missing = []
    existing = root
    until existing.exist? || existing.symlink?
      missing.unshift(existing)
      existing = existing.dirname
    end
    reject_link(existing, existing.to_s)
    if !existing.directory?
      raise ArtifactStore::InvalidObject, "Local artifact root parent must be a directory: #{existing}"
    end
    missing.each { create_directory(_1.dirname, _1) }
  end

  # Creates one directory and waits for its parent to record the change on disk.
  def create_directory(parent, directory)
    Dir.mkdir(directory)
    fsync_directory(parent)
  rescue Errno::EEXIST
    nil
  rescue StandardError
    begin
      Dir.rmdir(directory)
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      nil
    end
    raise
  end

  # Creates or returns the private directory used for unfinished writes.
  def temporary_directory
    prepare_root
    directory = root.join(ArtifactStore::INTERNAL_SEGMENT)
    create_directory(root, directory) if !directory.exist? && !directory.symlink?
    reject_link(directory, ArtifactStore::INTERNAL_SEGMENT)
    if !directory.directory?
      raise ArtifactStore::InvalidObject, "Local artifact temporary path must be a directory"
    end
    directory
  rescue Errno::EEXIST
    retry
  end

  # Returns name's contents file, or raises if it is missing or not a file.
  def readable_object(name)
    object = object_file(name)
    raise ArtifactStore::Missing, "Artifact object does not exist: #{name}" if !object.exist? && !object.symlink?
    if !regular_file?(object, name)
      raise ArtifactStore::InvalidObject, "Artifact object must be a file: #{name}"
    end

    object
  end

  # Collects every stored file name at or below one directory.
  def collect_objects(directory, name)
    reject_link(directory, name)
    if !directory.directory?
      raise ArtifactStore::InvalidObject, "Local artifact storage path must be a directory: #{name}"
    end

    Dir.each_child(directory).flat_map do |entry|
      path = directory.join(entry)
      reject_link(path, "#{name}/#{entry}")
      if entry == ArtifactStore::INTERNAL_SEGMENT
        collect_object(path, name)
      elsif path.directory?
        collect_objects(path, "#{name}/#{entry}")
      else
        raise ArtifactStore::InvalidObject, "Local artifact storage path must be a directory: #{name}/#{entry}"
      end
    end
  end

  # Returns name in a list, or raises if path is not a file.
  def collect_object(path, name)
    if !regular_file?(path, name)
      raise ArtifactStore::InvalidObject, "Artifact object must be a file: #{name}"
    end

    [ name ]
  end

  # Reports whether a path is an ordinary file and not a symbolic link.
  def regular_file?(path, name)
    reject_link(path, name)
    path.file?
  end

  # Raises when a local storage path is a symbolic link.
  def reject_link(path, name)
    if path.symlink?
      raise ArtifactStore::InvalidObject, "Artifact storage paths cannot be symbolic links: #{name}"
    end
  end

  # Copies source into destination in chunks and returns the bytes written.
  def stream(source, destination)
    bytes = 0
    while (chunk = source.read(BUFFER_BYTES))
      break if chunk.empty?

      bytes += destination.write(chunk)
    end
    bytes
  end
end
