# frozen_string_literal: true

require_relative "../abstract_unit"
require "active_support/hash_with_indifferent_access"
require "benchmark/ips"

module ActiveSupport
  class HashWithIndifferentAccessPerformanceTest < ActiveSupport::TestCase
    def setup
      # Warm up the cache with common keys
      common_keys = [:id, :name, :email, :created_at, :updated_at, :user_id, :post_id, :comment_id]
      HashWithIndifferentAccess.warm_up_cache(common_keys)
    end

    def teardown
      HashWithIndifferentAccess.shutdown
    end

    def test_key_conversion_performance_improvement
      # Test that key caching provides measurable performance improvement
      symbol_keys = [:user_id, :post_title, :comment_body, :created_at, :updated_at]
      
      Benchmark.ips do |x|
        x.report("symbol.name (original)") do
          symbol_keys.each { |key| key.name }
        end
        
        x.report("key_cache.get_or_create (optimized)") do
          symbol_keys.each { |key| HashWithIndifferentAccessCache.key_cache.get_or_create(key) }
        end
        
        x.compare!
      end
      
      # Verify that caching is actually faster
      time_original = Benchmark.measure { 10000.times { symbol_keys.each { |key| key.name } } }
      time_cached = Benchmark.measure { 10000.times { symbol_keys.each { |key| HashWithIndifferentAccessCache.key_cache.get_or_create(key) } } }
      
      assert time_cached.total < time_original.total, "Key caching should be faster than repeated symbol.name calls"
    end

    def test_object_creation_performance_improvement
      # Test that object pooling provides measurable performance improvement
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      Benchmark.ips do |x|
        x.report("HashWithIndifferentAccess.new (original)") do
          HashWithIndifferentAccess.new(test_data)
        end
        
        x.report("object_pool.acquire (optimized)") do
          hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
          hash.replace(test_data)
          ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
        end
        
        x.compare!
      end
      
      # Verify that pooling is actually faster
      time_original = Benchmark.measure { 1000.times { HashWithIndifferentAccess.new(test_data) } }
      time_pooled = Benchmark.measure { 1000.times { 
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash.replace(test_data)
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      } }
      
      assert time_pooled.total < time_original.total, "Object pooling should be faster than repeated object creation"
    end

    def test_hash_operations_performance
      # Test that hash operations maintain performance with optimizations
      large_hash = HashWithIndifferentAccess.new
      1000.times { |i| large_hash["key_#{i}".to_sym] = "value_#{i}" }
      
      symbol_keys = large_hash.keys.first(100).map(&:to_sym)
      string_keys = large_hash.keys.first(100)
      
      Benchmark.ips do |x|
        x.report("symbol key access") do
          symbol_keys.each { |key| large_hash[key] }
        end
        
        x.report("string key access") do
          string_keys.each { |key| large_hash[key] }
        end
        
        x.compare!
      end
      
      # Both should be fast due to key caching
      time_symbols = Benchmark.measure { 1000.times { symbol_keys.each { |key| large_hash[key] } } }
      time_strings = Benchmark.measure { 1000.times { string_keys.each { |key| large_hash[key] } } }
      
      assert time_symbols.total < 0.1, "Symbol key access should be very fast"
      assert time_strings.total < 0.1, "String key access should be very fast"
    end

    def test_concurrent_access_performance
      # Test performance under concurrent access
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      Benchmark.ips do |x|
        x.report("single-threaded pooling") do
          100.times do
            hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
            hash.replace(test_data)
            hash[:extra] = "value"
            ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
          end
        end
        
        x.report("multi-threaded pooling") do
          threads = []
          10.times do
            threads << Thread.new do
              10.times do
                hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
                hash.replace(test_data)
                hash[:extra] = "value"
                ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
              end
            end
          end
          threads.each(&:join)
        end
        
        x.compare!
      end
    end

    def test_memory_allocation_reduction
      # Test that optimizations actually reduce memory allocations
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      # Measure memory allocation without optimizations
      memory_original = measure_memory_allocation do
        100.times do
          hash = HashWithIndifferentAccess.new(test_data)
          hash[:extra] = "value"
        end
      end
      
      # Measure memory allocation with optimizations
      memory_optimized = measure_memory_allocation do
        100.times do
          hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
          hash.replace(test_data)
          hash[:extra] = "value"
          ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
        end
      end
      
      # Should have fewer allocations with optimizations
      assert memory_optimized < memory_original, "Optimizations should reduce memory allocations"
      
      # Calculate improvement percentage
      improvement = ((memory_original - memory_optimized) / memory_original * 100).round(2)
      puts "Memory allocation improvement: #{improvement}%"
    end

    def test_garbage_collection_pressure_reduction
      # Test reduction in GC pressure
      initial_gc_count = GC.count
      
      # Create many objects without pooling
      1000.times do
        hash = HashWithIndifferentAccess.new
        hash[:test] = "value"
      end
      
      # Force GC
      GC.start
      gc_count_without_pooling = GC.count
      
      # Create many objects with pooling
      1000.times do
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash[:test] = "value"
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      end
      
      # Force GC
      GC.start
      gc_count_with_pooling = GC.count
      
      # Should have fewer GC runs with pooling
      gc_runs_without_pooling = gc_count_without_pooling - initial_gc_count
      gc_runs_with_pooling = gc_count_with_pooling - gc_count_without_pooling
      
      assert gc_runs_with_pooling <= gc_runs_without_pooling, "Object pooling should reduce GC pressure"
      
      puts "GC runs without pooling: #{gc_runs_without_pooling}"
      puts "GC runs with pooling: #{gc_runs_with_pooling}"
    end

    def test_real_world_scenario_performance
      # Simulate a real-world scenario with nested hashes
      user_data = {
        id: 123,
        profile: {
          name: "John Doe",
          email: "john@example.com",
          preferences: {
            theme: "dark",
            notifications: true
          }
        },
        posts: [
          { id: 1, title: "First Post", content: "Hello World" },
          { id: 2, title: "Second Post", content: "Another post" }
        ]
      }
      
      Benchmark.ips do |x|
        x.report("traditional conversion") do
          100.times do
            HashWithIndifferentAccess.new(user_data)
          end
        end
        
        x.report("with object pooling") do
                  100.times do
          hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
          hash.replace(user_data)
          ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
        end
        end
        
        x.compare!
      end
      
      # Verify improvement
      time_conversion = Benchmark.measure { 100.times { HashWithIndifferentAccess.new(user_data) } }
      time_pooled = Benchmark.measure { 100.times { 
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash.replace(user_data)
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      } }
      
      assert time_pooled.total < time_conversion.total, "Object pooling should be faster for real-world scenarios"
    end

    def test_configuration_performance_impact
      # Test performance with different pool sizes
      pool_sizes = [10, 50, 100, 500]
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      Benchmark.ips do |x|
        pool_sizes.each do |size|
          HashWithIndifferentAccess.configure_pool(pool_size: size)
          
          x.report("pool size #{size}") do
            100.times do
              hash = HashWithIndifferentAccess.object_pool.acquire
              hash.replace(test_data)
              hash[:extra] = "value"
              HashWithIndifferentAccess.object_pool.release(hash)
            end
          end
        end
        
        x.compare!
      end
    end

    private

    def measure_memory_allocation
      # Simple memory allocation measurement
      initial_objects = ObjectSpace.count_objects[:T_HASH]
      yield
      final_objects = ObjectSpace.count_objects[:T_HASH]
      final_objects - initial_objects
    end
  end
end
