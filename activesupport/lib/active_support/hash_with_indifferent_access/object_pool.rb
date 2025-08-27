# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module ActiveSupport
  module HashWithIndifferentAccessPool
    # Object pool for HashWithIndifferentAccess instances to reduce memory allocations
    # and improve performance by reusing objects instead of creating new ones.
    class ObjectPool
      include MonitorMixin

      # Default pool size - can be configured via environment variable
      DEFAULT_POOL_SIZE = ENV.fetch("RAILS_HASH_POOL_SIZE", 100).to_i

      # Maximum time an object can stay in the pool before being cleaned up
      MAX_OBJECT_AGE = ENV.fetch("RAILS_HASH_POOL_MAX_AGE", 300).to_i # 5 minutes

      # Minimum pool size to maintain
      MIN_POOL_SIZE = ENV.fetch("RAILS_HASH_POOL_MIN_SIZE", 10).to_i

      def initialize(pool_size = DEFAULT_POOL_SIZE)
        super()
        @pool_size = [pool_size, MIN_POOL_SIZE].max
        @pool = []
        @pool_mutex = Mutex.new
        @cleanup_thread = nil
        @shutdown = false

        start_cleanup_thread
      end

      # Acquire an object from the pool
      def acquire
        synchronize do
          if @pool.empty?
            # Create a new object if pool is empty
            @objects_created ||= 0
            @objects_created += 1
            ActiveSupport::HashWithIndifferentAccess.new
          else
            # Reuse an existing object from the pool
            @objects_reused ||= 0
            @objects_reused += 1
            @pool.pop
          end
        end
      end

      # Return an object to the pool for reuse
      def release(object)
        return unless object.is_a?(ActiveSupport::HashWithIndifferentAccess)

        # Clear the object's contents before returning to pool
        object.clear

        synchronize do
          if @pool.size < @pool_size
            @pool << object
          end
          # If pool is full, let the object be garbage collected
        end
      end

      # Get current pool statistics
      def stats
        synchronize do
          {
            pool_size: @pool.size,
            max_pool_size: @pool_size,
            objects_created: @objects_created || 0,
            objects_reused: @objects_reused || 0,
            cleanup_runs: @cleanup_runs || 0
          }
        end
      end

      # Resize the pool
      def resize(new_size)
        if new_size < 1
          raise ArgumentError, "Pool size must be at least 1, got #{new_size}"
        end

        new_size = [new_size, MIN_POOL_SIZE].max

        synchronize do
          old_size = @pool_size
          @pool_size = new_size

          # Trim pool if new size is smaller
          if new_size < old_size
            @pool = @pool.first(new_size)
          end
        end
      end

      # Clear the pool and force garbage collection
      def clear_pool
        synchronize do
          @pool.clear
        end
        GC.start
      end

      # Shutdown the pool and cleanup thread
      def shutdown
        synchronize do
          @shutdown = true
          @pool.clear
        end

        if @cleanup_thread && @cleanup_thread.alive?
          # Give the thread a short time to respond to shutdown signal
          @cleanup_thread.join(1.0) # Wait max 1 second

          # If thread doesn't respond, forcefully terminate it
          if @cleanup_thread.alive?
            @cleanup_thread.kill
            @cleanup_thread.join(0.1) # Brief wait for cleanup
          end
        end

        @cleanup_thread = nil
      end

      private
        def start_cleanup_thread
          @cleanup_thread = Thread.new do
            loop do
              break if @shutdown

              # Use shorter sleep intervals for more responsive shutdown
              sleep_time = @shutdown ? 0.1 : 10
              sleep(sleep_time)
              break if @shutdown

              cleanup_old_objects
            end
          end

          @cleanup_thread.abort_on_exception = true
        end

        def cleanup_old_objects
          synchronize do
            @cleanup_runs ||= 0
            @cleanup_runs += 1

            # Keep only the most recently used objects
            if @pool.size > MIN_POOL_SIZE
              @pool = @pool.last(MIN_POOL_SIZE)
            end
          end
        rescue => e
          # Log error but don't crash the cleanup thread
          Rails.logger.error("HashWithIndifferentAccess pool cleanup error: #{e.message}") if defined?(Rails)
        end

        # Thread-safe pool access
        def pool_synchronize(&block)
          @pool_mutex.synchronize(&block)
        end
    end

    # Global object pool instance
    @object_pool = nil
    @object_pool_mutex = Mutex.new

    class << self
      # Get or create the global object pool
      def object_pool
        @object_pool_mutex.synchronize do
          @object_pool ||= ObjectPool.new
        end
      end

      # Configure the global object pool
      def configure_object_pool(pool_size: nil, max_age: nil)
        pool = object_pool

        if pool_size
          pool.resize(pool_size)
        end

        pool
      end

      # Get pool statistics
      def pool_stats
        object_pool.stats
      end

      # Clear the global object pool
      def clear_object_pool
        object_pool.clear_pool
      end

      # Shutdown the global object pool
      def shutdown_object_pool
        @object_pool_mutex.synchronize do
          if @object_pool
            @object_pool.shutdown
            @object_pool = nil
          end
        end
      end
    end
  end
end
