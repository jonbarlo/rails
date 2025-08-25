# frozen_string_literal: true

require "test_helper"
require "active_support/hash_with_indifferent_access/object_pool"
require "active_support/hash_with_indifferent_access/key_cache"

module ActiveSupport
  class HashWithIndifferentAccessObjectPoolTest < ActiveSupport::TestCase
    def setup
      @pool = HashWithIndifferentAccess::ObjectPool.new(10)
      @cache = HashWithIndifferentAccess::KeyCache.new(100)
    end

    def teardown
      @pool.shutdown
      @cache.shutdown
    end

    def test_pool_initialization
      assert_equal 10, @pool.stats[:max_pool_size]
      assert_equal 0, @pool.stats[:pool_size]
    end

    def test_object_acquisition
      obj1 = @pool.acquire
      obj2 = @pool.acquire
      
      assert_instance_of HashWithIndifferentAccess, obj1
      assert_instance_of HashWithIndifferentAccess, obj2
      assert_not_equal obj1.object_id, obj2.object_id
      
      assert_equal 0, @pool.stats[:pool_size]
    end

    def test_object_release
      obj = @pool.acquire
      obj[:test] = "value"
      
      @pool.release(obj)
      
      assert_equal 1, @pool.stats[:pool_size]
      assert_empty obj
    end

    def test_pool_size_limit
      # Fill the pool
      objects = []
      10.times do
        obj = @pool.acquire
        obj[:test] = "value"
        @pool.release(obj)
        objects << obj
      end
      
      assert_equal 10, @pool.stats[:pool_size]
      
      # Try to release one more - should not exceed pool size
      extra_obj = HashWithIndifferentAccess.new
      extra_obj[:extra] = "value"
      @pool.release(extra_obj)
      
      assert_equal 10, @pool.stats[:pool_size]
    end

    def test_pool_resize
      @pool.resize(5)
      assert_equal 5, @pool.stats[:max_pool_size]
      
      # Fill the pool
      5.times do
        obj = @pool.acquire
        @pool.release(obj)
      end
      
      assert_equal 5, @pool.stats[:pool_size]
      
      # Resize smaller - should trim pool
      @pool.resize(3)
      assert_equal 3, @pool.stats[:pool_size]
      assert_equal 3, @pool.stats[:max_pool_size]
    end

    def test_pool_cleanup
      # Fill the pool
      10.times do
        obj = @pool.acquire
        @pool.release(obj)
      end
      
      assert_equal 10, @pool.stats[:pool_size]
      
      # Force cleanup
      @pool.send(:cleanup_old_objects)
      
      # Should maintain minimum pool size
      assert_equal 10, @pool.stats[:pool_size]
    end

    def test_pool_clear
      # Fill the pool
      5.times do
        obj = @pool.acquire
        @pool.release(obj)
      end
      
      assert_equal 5, @pool.stats[:pool_size]
      
      @pool.clear_pool
      assert_equal 0, @pool.stats[:pool_size]
    end

    def test_pool_shutdown
      @pool.shutdown
      assert @pool.instance_variable_get(:@shutdown)
    end

    def test_key_cache_initialization
      assert_equal 100, @cache.stats[:max_cache_size]
      assert_equal 0, @cache.stats[:cache_size]
    end

    def test_symbol_to_string_caching
      symbol_key = :test_key
      
      # First access should create and cache
      string1 = @cache.get_or_create(symbol_key)
      assert_equal "test_key", string1
      assert string1.frozen?
      assert_equal 1, @cache.stats[:cache_size]
      
      # Second access should return cached string
      string2 = @cache.get_or_create(symbol_key)
      assert_equal string1, string2
      assert_equal string1.object_id, string2.object_id
      assert_equal 1, @cache.stats[:cache_size]
    end

    def test_non_symbol_keys
      string_key = "test_key"
      number_key = 123
      
      # Non-symbol keys should be returned as-is
      assert_equal string_key, @cache.get_or_create(string_key)
      assert_equal number_key, @cache.get_or_create(number_key)
      assert_equal 0, @cache.stats[:cache_size]
    end

    def test_cache_size_limit
      # Fill the cache
      100.times do |i|
        @cache.get_or_create("key_#{i}".to_sym)
      end
      
      assert_equal 100, @cache.stats[:cache_size]
      
      # Add one more - should trigger cleanup
      @cache.get_or_create(:extra_key)
      
      # Should maintain cache size limit
      assert @cache.stats[:cache_size] <= 100
    end

    def test_cache_warm_up
      keys = [:user, :email, :password, :created_at, :updated_at]
      
      @cache.warm_up(keys)
      
      assert_equal 5, @cache.stats[:cache_size]
      
      # All keys should be cached
      keys.each do |key|
        assert @cache.cached?(key)
      end
    end

    def test_cache_clear
      @cache.get_or_create(:test_key)
      assert_equal 1, @cache.stats[:cache_size]
      
      @cache.clear
      assert_equal 0, @cache.stats[:cache_size]
    end

    def test_cache_shutdown
      @cache.shutdown
      assert @cache.instance_variable_get(:@shutdown)
    end

    def test_integration_with_hash_with_indifferent_access
      # Test that the object pool and key cache work together
      hash = HashWithIndifferentAccess.new
      
      # Use symbol keys to test key caching
      hash[:user_id] = 123
      hash[:email] = "test@example.com"
      
      # Test key conversion caching
      assert_equal "user_id", hash.keys[0]
      assert_equal "email", hash.keys[1]
      
      # Test object pooling
      indifferent_hash = hash.with_indifferent_access
      assert_instance_of HashWithIndifferentAccess, indifferent_hash
      assert_equal hash[:user_id], indifferent_hash[:user_id]
      assert_equal hash[:email], indifferent_hash[:email]
    end

    def test_performance_improvement
      # Benchmark the performance improvement
      require "benchmark"
      
      # Test without caching (original behavior)
      time_without_cache = Benchmark.measure do
        1000.times do
          :test_key.to_s
        end
      end
      
      # Test with caching
      time_with_cache = Benchmark.measure do
        1000.times do
          @cache.get_or_create(:test_key)
        end
      end
      
      # Caching should be faster
      assert time_with_cache.total < time_without_cache.total
    end

    def test_memory_usage_reduction
      # Test that object pooling reduces memory allocations
      initial_objects = ObjectSpace.count_objects[:T_HASH]
      
      # Create many HashWithIndifferentAccess objects
      objects = []
      100.times do
        obj = @pool.acquire
        obj[:test] = "value"
        objects << obj
      end
      
      # Return objects to pool
      objects.each { |obj| @pool.release(obj) }
      
      # Force garbage collection
      GC.start
      
      final_objects = ObjectSpace.count_objects[:T_HASH]
      
      # Should not have created excessive new objects
      assert final_objects - initial_objects < 100
    end

    def test_thread_safety
      # Test that pool and cache are thread-safe
      threads = []
      results = []
      
      5.times do |i|
        threads << Thread.new do
          obj = @pool.acquire
          obj[:thread_id] = i
          @pool.release(obj)
          
          symbol = "key_#{i}".to_sym
          string = @cache.get_or_create(symbol)
          results << [i, string]
        end
      end
      
      threads.each(&:join)
      
      # All threads should complete successfully
      assert_equal 5, results.length
      
      # Check that results are correct
      results.each do |thread_id, string|
        assert_equal "key_#{thread_id}", string
      end
    end
  end
end
