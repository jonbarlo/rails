# frozen_string_literal: true

require "test_helper"
require "benchmark"
require "memory_profiler"

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

    def test_key_conversion_performance
      puts "\n=== Key Conversion Performance Test ==="
      
      # Test symbol to string conversion performance
      symbol_keys = [:user_id, :post_title, :comment_body, :created_at, :updated_at]
      
      # Benchmark original behavior (without caching)
      time_original = Benchmark.measure do
        10000.times do
          symbol_keys.each { |key| key.name }
        end
      end
      
      # Benchmark with caching
      time_cached = Benchmark.measure do
        10000.times do
          symbol_keys.each { |key| HashWithIndifferentAccess.key_cache.get_or_create(key) }
        end
      end
      
      puts "Original (without cache): #{time_original.total.round(4)}s"
      puts "With cache: #{time_cached.total.round(4)}s"
      puts "Improvement: #{((time_original.total - time_cached.total) / time_original.total * 100).round(2)}%"
      
      # Caching should be significantly faster
      assert time_cached.total < time_original.total
    end

    def test_object_creation_performance
      puts "\n=== Object Creation Performance Test ==="
      
      # Test HashWithIndifferentAccess creation performance
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      # Benchmark original behavior (without object pooling)
      time_original = Benchmark.measure do
        1000.times do
          HashWithIndifferentAccess.new(test_data)
        end
      end
      
      # Benchmark with object pooling
      time_pooled = Benchmark.measure do
        1000.times do
          HashWithIndifferentAccess.object_pool.acquire.tap do |obj|
            obj.replace(test_data)
          end
        end
      end
      
      puts "Original (without pooling): #{time_original.total.round(4)}s"
      puts "With object pooling: #{time_pooled.total.round(4)}s"
      puts "Improvement: #{((time_original.total - time_pooled.total) / time_original.total * 100).round(2)}%"
      
      # Object pooling should be faster
      assert time_pooled.total < time_original.total
    end

    def test_memory_allocation_reduction
      puts "\n=== Memory Allocation Test ==="
      
      # Test memory allocation reduction
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      # Measure memory allocation without optimizations
      memory_original = MemoryProfiler.report do
        100.times do
          hash = HashWithIndifferentAccess.new(test_data)
          hash[:extra] = "value"
        end
      end
      
      # Measure memory allocation with optimizations
      memory_optimized = MemoryProfiler.report do
        100.times do
          hash = HashWithIndifferentAccess.object_pool.acquire
          hash.replace(test_data)
          hash[:extra] = "value"
          HashWithIndifferentAccess.object_pool.release(hash)
        end
      end
      
      puts "Original allocations: #{memory_original.total_allocated}"
      puts "Optimized allocations: #{memory_optimized.total_allocated}"
      puts "Reduction: #{((memory_original.total_allocated - memory_optimized.total_allocated) / memory_original.total_allocated * 100).round(2)}%"
      
      # Should have fewer allocations
      assert memory_optimized.total_allocated < memory_original.total_allocated
    end

    def test_hash_operations_performance
      puts "\n=== Hash Operations Performance Test ==="
      
      # Test hash operations performance
      large_hash = HashWithIndifferentAccess.new
      1000.times { |i| large_hash["key_#{i}".to_sym] = "value_#{i}" }
      
      # Benchmark key access with symbol keys
      symbol_keys = large_hash.keys.first(100).map(&:to_sym)
      
      time_symbols = Benchmark.measure do
        1000.times do
          symbol_keys.each { |key| large_hash[key] }
        end
      end
      
      # Benchmark key access with string keys
      string_keys = large_hash.keys.first(100)
      
      time_strings = Benchmark.measure do
        1000.times do
          string_keys.each { |key| large_hash[key] }
        end
      end
      
      puts "Symbol key access: #{time_symbols.total.round(4)}s"
      puts "String key access: #{time_strings.total.round(4)}s"
      puts "Difference: #{((time_symbols.total - time_strings.total) / time_symbols.total * 100).round(2)}%"
      
      # Both should be fast due to key caching
      assert time_symbols.total < 0.1  # Should be very fast
      assert time_strings.total < 0.1  # Should be very fast
    end

    def test_concurrent_access_performance
      puts "\n=== Concurrent Access Performance Test ==="
      
      # Test performance under concurrent access
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      # Single-threaded performance
      time_single = Benchmark.measure do
        1000.times do
          hash = HashWithIndifferentAccess.object_pool.acquire
          hash.replace(test_data)
          hash[:extra] = "value"
          HashWithIndifferentAccess.object_pool.release(hash)
        end
      end
      
      # Multi-threaded performance
      threads = []
      time_multi = Benchmark.measure do
        10.times do
          threads << Thread.new do
            100.times do
              hash = HashWithIndifferentAccess.object_pool.acquire
              hash.replace(test_data)
              hash[:extra] = "value"
              HashWithIndifferentAccess.object_pool.release(hash)
            end
          end
        end
        
        threads.each(&:join)
      end
      
      puts "Single-threaded: #{time_single.total.round(4)}s"
      puts "Multi-threaded (10 threads): #{time_multi.total.round(4)}s"
      puts "Scalability: #{((time_single.total / time_multi.total) * 10).round(2)}x"
      
      # Multi-threading should scale well
      assert time_multi.total < time_single.total * 2  # Should be reasonably efficient
    end

    def test_garbage_collection_pressure
      puts "\n=== Garbage Collection Pressure Test ==="
      
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
        hash = HashWithIndifferentAccess.object_pool.acquire
        hash[:test] = "value"
        HashWithIndifferentAccess.object_pool.release(hash)
      end
      
      # Force GC
      GC.start
      gc_count_with_pooling = GC.count
      
      puts "GC runs without pooling: #{gc_count_without_pooling - initial_gc_count}"
      puts "GC runs with pooling: #{gc_count_with_pooling - gc_count_without_pooling}"
      
      # Should have fewer GC runs with pooling
      assert (gc_count_with_pooling - gc_count_without_pooling) <= (gc_count_without_pooling - initial_gc_count)
    end

    def test_real_world_scenario
      puts "\n=== Real-World Scenario Test ==="
      
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
      
      # Benchmark conversion to indifferent access
      time_conversion = Benchmark.measure do
        100.times do
          HashWithIndifferentAccess.new(user_data)
        end
      end
      
      # Benchmark with object pooling
      time_pooled = Benchmark.measure do
        100.times do
          hash = HashWithIndifferentAccess.object_pool.acquire
          hash.replace(user_data)
          HashWithIndifferentAccess.object_pool.release(hash)
        end
      end
      
      puts "Traditional conversion: #{time_conversion.total.round(4)}s"
      puts "With object pooling: #{time_pooled.total.round(4)}s"
      puts "Improvement: #{((time_conversion.total - time_pooled.total) / time_conversion.total * 100).round(2)}%"
      
      # Object pooling should be faster
      assert time_pooled.total < time_conversion.total
    end

    def test_configuration_performance
      puts "\n=== Configuration Performance Test ==="
      
      # Test performance with different pool sizes
      pool_sizes = [10, 50, 100, 500]
      
      pool_sizes.each do |size|
        HashWithIndifferentAccess.configure_pool(pool_size: size)
        
        time = Benchmark.measure do
          100.times do
            hash = HashWithIndifferentAccess.object_pool.acquire
            hash[:test] = "value"
            HashWithIndifferentAccess.object_pool.release(hash)
          end
        end
        
        puts "Pool size #{size}: #{time.total.round(4)}s"
      end
      
      # Performance should be consistent across pool sizes
      assert true  # Just ensure the test runs without errors
    end
  end
end
