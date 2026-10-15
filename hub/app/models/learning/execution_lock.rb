# Serializes actual learning mutations, not time spent waiting in Solid Queue's ready queue.
class Learning::ExecutionLock
  class Busy < StandardError; end

  KEY = :replica_learning_execution_lock
  # About an hour of lock contention becomes a visible failed execution, not an endless retry.
  RETRY = { wait: 30.seconds, attempts: 121 }.freeze

  # Child writers inherit this descriptor so a stopped worker cannot release protection early.
  def self.current
    Thread.current.thread_variable_get(KEY)
  end

  # Retries a busy operation before it claims a run or reads a snapshot.
  def self.synchronize
    raise Busy, "Another learning operation is still running." if current

    lock = open_lock
    begin
      acquire!(lock)
      Thread.current.thread_variable_set(KEY, lock)
      yield
    ensure
      Thread.current.thread_variable_set(KEY, nil)
      # Do not LOCK_UN: a surviving SDK child must retain the shared open-description lock.
      lock.close
    end
  end

  # The private root is shared by every worker in the supported single-container deployment.
  def self.open_lock
    root = Rails.configuration.x.learning_root
    PrivateStorageRoot.validate!(root, name: "REPLICA_LEARNING_ROOT", application_root: Rails.root, public_root: Rails.public_path)
    FileUtils.mkdir_p(root, mode: 0o700)
    lock = File.open(root, File::RDONLY | File::NOFOLLOW)
    prepared = false
    begin
      PrivateStorageRoot.validate!(root, name: "REPLICA_LEARNING_ROOT", application_root: Rails.root, public_root: Rails.public_path)
      if !lock.stat.directory? || !File.identical?(root, lock)
        raise Learning::Error.new("The learning root changed before Hub could lock it.", code: "unavailable")
      end

      lock.chmod(0o700)
      prepared = true
      lock
    ensure
      lock.close if !prepared
    end
  rescue PrivateStorageRoot::Invalid, SystemCallError => error
    raise Learning::Error.new("Hub could not open its learning execution lock: #{error.message}", code: "unavailable")
  end
  private_class_method :open_lock

  # Busy workers return to the queue rather than occupying a thread while another run finishes.
  def self.acquire!(lock)
    return if lock.flock(File::LOCK_EX | File::LOCK_NB)

    raise Busy, "Another learning operation is still running."
  rescue SystemCallError => error
    raise Learning::Error.new("Hub could not acquire its learning execution lock: #{error.message}", code: "unavailable")
  end
  private_class_method :acquire!
end
