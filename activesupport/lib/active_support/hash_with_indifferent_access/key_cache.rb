# frozen_string_literal: true

require "thread"

module ActiveSupport
  module HashWithIndifferentAccessCache
    # Key cache for HashWithIndifferentAccess to reduce string allocations
    # by caching symbol-to-string conversions and reusing frozen strings.
    class KeyCache
      include MonitorMixin

      # Default cache size - can be configured via environment variable
      DEFAULT_CACHE_SIZE = ENV.fetch("RAILS_HASH_KEY_CACHE_SIZE", 1000).to_i

      # Maximum cache size to prevent memory bloat
      MAX_CACHE_SIZE = ENV.fetch("RAILS_HASH_KEY_CACHE_MAX_SIZE", 10000).to_i

      # Minimum cache size to maintain
      MIN_CACHE_SIZE = ENV.fetch("RAILS_HASH_KEY_CACHE_MIN_SIZE", 100).to_i

      def initialize(cache_size = DEFAULT_CACHE_SIZE)
        super()
        @cache_size = [cache_size, MIN_CACHE_SIZE].max
        @cache = {}
        @cache_mutex = Mutex.new
        @access_count = {}
        @cleanup_thread = nil
        @shutdown = false
        
        start_cleanup_thread
      end

      # Get or create a cached string for a symbol key
      def get_or_create(symbol_key)
        return symbol_key unless symbol_key.is_a?(Symbol)
        
        # Check cache first
        cached_string = cache_get(symbol_key)
        return cached_string if cached_string
        
        # Create new frozen string and cache it
        new_string = symbol_key.name.freeze
        cache_set(symbol_key, new_string)
        new_string
      end

      # Get a cached string for a symbol key
      def get(symbol_key)
        return symbol_key unless symbol_key.is_a?(Symbol)
        cache_get(symbol_key)
      end

      # Check if a key is cached
      def cached?(symbol_key)
        return false unless symbol_key.is_a?(Symbol)
        cache_has_key?(symbol_key)
      end

      # Get cache statistics
      def stats
        synchronize do
          {
            cache_size: @cache.size,
            max_cache_size: @cache_size,
            total_accesses: @access_count.values.sum,
            most_accessed: @access_count.max_by { |_, count| count }&.first,
            cleanup_runs: @cleanup_runs || 0
          }
        end
      end

      # Resize the cache
      def resize(new_size)
        new_size = [new_size, MIN_CACHE_SIZE].max
        
        synchronize do
          old_size = @cache_size
          @cache_size = new_size
          
          # Trim cache if new size is smaller
          if new_size < old_size
            trim_cache(new_size)
          end
        end
      end

      # Clear the cache
      def clear
        synchronize do
          @cache.clear
          @access_count.clear
        end
      end

      # Warm up the cache with common keys
      def warm_up(keys)
        keys.each do |key|
          get_or_create(key) if key.is_a?(Symbol)
        end
      end

      # Shutdown the cache and cleanup thread
      def shutdown
        synchronize do
          @shutdown = true
          @cache.clear
          @access_count.clear
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

        def cache_get(symbol_key)
          synchronize do
            if @cache.key?(symbol_key)
              @access_count[symbol_key] ||= 0
              @access_count[symbol_key] += 1
              @cache[symbol_key]
            end
          end
        end

        def cache_set(symbol_key, string_value)
          synchronize do
            # Check if we need to trim the cache
            if @cache.size >= @cache_size
              trim_cache(@cache_size - 1)
            end
            
            @cache[symbol_key] = string_value
            @access_count[symbol_key] = 1
          end
        end

        def cache_has_key?(symbol_key)
          synchronize do
            @cache.key?(symbol_key)
          end
        end

        def trim_cache(target_size)
          return if @cache.size <= target_size
          
          # Remove least accessed keys
          keys_to_remove = @cache.size - target_size
          sorted_keys = @access_count.sort_by { |_, count| count }.first(keys_to_remove)
          
          sorted_keys.each do |key, _|
            @cache.delete(key)
            @access_count.delete(key)
          end
        end

        def start_cleanup_thread
          @cleanup_thread = Thread.new do
            loop do
              break if @shutdown
              
              # Use shorter sleep intervals for more responsive shutdown
              sleep_time = @shutdown ? 0.1 : 30
              sleep(sleep_time)
              break if @shutdown
              
              cleanup_old_entries
            end
          end
          
          @cleanup_thread.abort_on_exception = true
        end

        def cleanup_old_entries
          synchronize do
            @cleanup_runs ||= 0
            @cleanup_runs += 1
            
            # Remove keys that haven't been accessed recently
            if @cache.size > MIN_CACHE_SIZE
              # Keep only the most frequently accessed keys
              target_size = [@cache_size / 2, MIN_CACHE_SIZE].max
              trim_cache(target_size)
            end
          end
        rescue => e
          # Log error but don't crash the cleanup thread
          Rails.logger.error("HashWithIndifferentAccess key cache cleanup error: #{e.message}") if defined?(Rails)
        end

        # Thread-safe cache access
        def cache_synchronize(&block)
          @cache_mutex.synchronize(&block)
        end
    end

    # Global key cache instance
    @key_cache = nil
    @key_cache_mutex = Mutex.new

    class << self
      # Get or create the global key cache
      def key_cache
        @key_cache_mutex.synchronize do
          @key_cache ||= KeyCache.new
        end
      end

      # Configure the global key cache
      def configure_key_cache(cache_size: nil, max_size: nil)
        cache = key_cache
        
        if cache_size
          cache.resize(cache_size)
        end
        
        cache
      end

      # Get cache statistics
      def key_cache_stats
        key_cache.stats
      end

      # Clear the global key cache
      def clear_key_cache
        key_cache.clear
      end

      # Warm up the global key cache with common keys
      def warm_up_key_cache(keys)
        key_cache.warm_up(keys)
      end

      # Shutdown the global key cache
      def shutdown_key_cache
        @key_cache_mutex.synchronize do
          if @key_cache
            @key_cache.shutdown
            @key_cache = nil
          end
        end
      end
    end
  end
end
