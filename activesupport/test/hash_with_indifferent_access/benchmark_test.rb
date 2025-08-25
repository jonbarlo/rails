# frozen_string_literal: true

require_relative "../abstract_unit"
require "active_support/hash_with_indifferent_access"
require "benchmark/ips"

module ActiveSupport
  class HashWithIndifferentAccessBenchmarkTest < ActiveSupport::TestCase
    def setup
      # Configure optimizations for benchmarking
      HashWithIndifferentAccess.configure_pool(pool_size: 100)
      HashWithIndifferentAccess.configure_cache(cache_size: 500)
      
      # Warm up cache with common keys
      common_keys = [:id, :name, :email, :created_at, :updated_at, :user_id, :post_id, :comment_id, :title, :body]
      HashWithIndifferentAccess.warm_up_cache(common_keys)
    end

    def teardown
      HashWithIndifferentAccess.shutdown
    end

    def test_key_conversion_benchmark
      # Benchmark key conversion performance
      symbol_keys = [:user_id, :post_title, :comment_body, :created_at, :updated_at, :author_name, :category, :tags]
      
      puts "\n=== Key Conversion Performance Benchmark ==="
      
      Benchmark.ips do |x|
        x.config(time: 2, warmup: 1)
        
        x.report("symbol.name (original)") do
          symbol_keys.each { |key| key.name }
        end
        
        x.report("key_cache.get_or_create (optimized)") do
          symbol_keys.each { |key| HashWithIndifferentAccessCache.key_cache.get_or_create(key) }
        end
        
        x.compare!
      end
      
      # Verify performance improvement
      verify_key_conversion_improvement(symbol_keys)
    end

    def test_object_creation_benchmark
      # Benchmark object creation performance
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com", created_at: Time.current }
      
      puts "\n=== Object Creation Performance Benchmark ==="
      
      Benchmark.ips do |x|
        x.config(time: 2, warmup: 1)
        
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
      
      # Verify performance improvement
      verify_object_creation_improvement(test_data)
    end

    def test_hash_operations_benchmark
      # Benchmark hash operations performance
      large_hash = HashWithIndifferentAccess.new
      1000.times { |i| large_hash["key_#{i}".to_sym] = "value_#{i}" }
      
      symbol_keys = large_hash.keys.first(100).map(&:to_sym)
      string_keys = large_hash.keys.first(100)
      
      puts "\n=== Hash Operations Performance Benchmark ==="
      
      Benchmark.ips do |x|
        x.config(time: 2, warmup: 1)
        
        x.report("symbol key access (100 keys)") do
          symbol_keys.each { |key| large_hash[key] }
        end
        
        x.report("string key access (100 keys)") do
          string_keys.each { |key| large_hash[key] }
        end
        
        x.compare!
      end
      
      # Verify performance
      verify_hash_operations_performance(large_hash, symbol_keys, string_keys)
    end

    def test_concurrent_access_benchmark
      # Benchmark concurrent access performance
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      puts "\n=== Concurrent Access Performance Benchmark ==="
      
      Benchmark.ips do |x|
        x.config(time: 2, warmup: 1)
        
        x.report("single-threaded pooling (100 ops)") do
          100.times do
            hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
            hash.replace(test_data)
            hash[:extra] = "value"
            ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
          end
        end
        
        x.report("multi-threaded pooling (10 threads, 10 ops each)") do
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
      
      # Verify scalability
      verify_concurrent_access_scalability(test_data)
    end

    def test_memory_allocation_benchmark
      # Benchmark memory allocation reduction
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      
      puts "\n=== Memory Allocation Benchmark ==="
      
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
      
      # Calculate improvement
      improvement = ((memory_original - memory_optimized) / memory_original * 100).round(2)
      
      puts "Memory allocation without optimizations: #{memory_original} objects"
      puts "Memory allocation with optimizations: #{memory_optimized} objects"
      puts "Improvement: #{improvement}%"
      
      # Should have fewer allocations with optimizations
      assert memory_optimized < memory_original, "Optimizations should reduce memory allocations"
      assert improvement > 0, "Should see measurable improvement"
    end

    def test_garbage_collection_benchmark
      # Benchmark GC pressure reduction
      puts "\n=== Garbage Collection Pressure Benchmark ==="
      
      initial_gc_count = GC.count
      initial_gc_time = GC.stat[:time]
      
      # Create many objects without pooling
      puts "Creating objects without pooling..."
      1000.times do
        hash = HashWithIndifferentAccess.new
        hash[:test] = "value"
      end
      
      GC.start
      gc_count_without_pooling = GC.count
      gc_time_without_pooling = GC.stat[:time]
      
      # Create many objects with pooling
      puts "Creating objects with pooling..."
      1000.times do
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash[:test] = "value"
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      end
      
      GC.start
      gc_count_with_pooling = GC.count
      gc_time_with_pooling = GC.stat[:time]
      
      # Calculate metrics
      gc_runs_without_pooling = gc_count_without_pooling - initial_gc_count
      gc_runs_with_pooling = gc_count_with_pooling - gc_count_without_pooling
      gc_time_without_pooling_total = gc_time_without_pooling - initial_gc_time
      gc_time_with_pooling_total = gc_time_with_pooling - gc_time_without_pooling
      
      puts "GC runs without pooling: #{gc_runs_without_pooling}"
      puts "GC runs with pooling: #{gc_runs_with_pooling}"
      puts "GC time without pooling: #{gc_time_without_pooling_total}ms"
      puts "GC time with pooling: #{gc_time_with_pooling_total}ms"
      
      # Should have fewer GC runs with pooling
      assert gc_runs_with_pooling <= gc_runs_without_pooling, "Object pooling should reduce GC pressure"
    end

    def test_real_world_scenario_benchmark
      # Benchmark real-world scenario performance
      user_data = {
        id: 123,
        profile: {
          name: "John Doe",
          email: "john@example.com",
          preferences: {
            theme: "dark",
            notifications: true,
            language: "en"
          }
        },
        posts: [
          { id: 1, title: "First Post", content: "Hello World", tags: ["intro", "hello"] },
          { id: 2, title: "Second Post", content: "Another post", tags: ["follow-up", "example"] }
        ],
        followers: [
          { id: 456, name: "Jane Smith", email: "jane@example.com" },
          { id: 789, name: "Bob Johnson", email: "bob@example.com" }
        ]
      }
      
      puts "\n=== Real-World Scenario Performance Benchmark ==="
      
      Benchmark.ips do |x|
        x.config(time: 2, warmup: 1)
        
        x.report("traditional conversion (100 times)") do
          100.times do
            HashWithIndifferentAccess.new(user_data)
          end
        end
        
        x.report("with object pooling (100 times)") do
          100.times do
            hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
            hash.replace(user_data)
            ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
          end
        end
        
        x.compare!
      end
      
      # Verify improvement
      verify_real_world_improvement(user_data)
    end

    def test_configuration_impact_benchmark
      # Benchmark performance with different configurations
      test_data = { user_id: 123, name: "John Doe", email: "john@example.com" }
      pool_sizes = [10, 50, 100, 200]
      
      puts "\n=== Configuration Impact Benchmark ==="
      
      Benchmark.ips do |x|
        x.config(time: 2, warmup: 1)
        
        pool_sizes.each do |size|
          HashWithIndifferentAccess.configure_pool(pool_size: size)
          
          x.report("pool size #{size}") do
            100.times do
              hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
              hash.replace(test_data)
              hash[:extra] = "value"
              ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
            end
          end
        end
        
        x.compare!
      end
    end

    private

    def verify_key_conversion_improvement(symbol_keys)
      # Verify that key caching provides measurable improvement
      iterations = 10000
      
      time_original = Benchmark.measure { iterations.times { symbol_keys.each { |key| key.name } } }
      time_cached = Benchmark.measure { iterations.times { symbol_keys.each { |key| HashWithIndifferentAccessCache.key_cache.get_or_create(key) } } }
      
      improvement = ((time_original.total - time_cached.total) / time_original.total * 100).round(2)
      
      puts "Key conversion improvement: #{improvement}%"
      assert time_cached.total < time_original.total, "Key caching should be faster"
      assert improvement > 0, "Should see measurable improvement"
    end

    def verify_object_creation_improvement(test_data)
      # Verify that object pooling provides measurable improvement
      iterations = 1000
      
      time_original = Benchmark.measure { iterations.times { HashWithIndifferentAccess.new(test_data) } }
      time_pooled = Benchmark.measure { iterations.times { 
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash.replace(test_data)
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      } }
      
      improvement = ((time_original.total - time_pooled.total) / time_original.total * 100).round(2)
      
      puts "Object creation improvement: #{improvement}%"
      assert time_pooled.total < time_original.total, "Object pooling should be faster"
      assert improvement > 0, "Should see measurable improvement"
    end

    def verify_hash_operations_performance(large_hash, symbol_keys, string_keys)
      # Verify that hash operations maintain performance
      iterations = 1000
      
      time_symbols = Benchmark.measure { iterations.times { symbol_keys.each { |key| large_hash[key] } } }
      time_strings = Benchmark.measure { iterations.times { string_keys.each { |key| large_hash[key] } } }
      
      puts "Symbol key access (1000 iterations): #{time_symbols.total.round(4)}s"
      puts "String key access (1000 iterations): #{time_strings.total.round(4)}s"
      
      # Both should be fast due to key caching
      assert time_symbols.total < 0.1, "Symbol key access should be very fast"
      assert time_strings.total < 0.1, "String key access should be very fast"
    end

    def verify_concurrent_access_scalability(test_data)
      # Verify that concurrent access scales well
      iterations = 100
      
      time_single = Benchmark.measure { iterations.times { 
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash.replace(test_data)
        hash[:extra] = "value"
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      } }
      
      threads = []
      time_multi = Benchmark.measure do
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
      
      puts "Single-threaded (100 ops): #{time_single.total.round(4)}s"
      puts "Multi-threaded (10 threads, 10 ops each): #{time_multi.total.round(4)}s"
      
      # Multi-threading should scale reasonably
      assert time_multi.total < time_single.total * 2, "Multi-threading should scale reasonably"
    end

    def verify_real_world_improvement(user_data)
      # Verify improvement in real-world scenarios
      iterations = 100
      
      time_conversion = Benchmark.measure { iterations.times { HashWithIndifferentAccess.new(user_data) } }
      time_pooled = Benchmark.measure { iterations.times { 
        hash = ActiveSupport::HashWithIndifferentAccessPool.object_pool.acquire
        hash.replace(user_data)
        ActiveSupport::HashWithIndifferentAccessPool.object_pool.release(hash)
      } }
      
      improvement = ((time_conversion.total - time_pooled.total) / time_conversion.total * 100).round(2)
      
      puts "Real-world scenario improvement: #{improvement}%"
      assert time_pooled.total < time_conversion.total, "Object pooling should be faster for real-world scenarios"
      assert improvement > 0, "Should see measurable improvement"
    end

    def measure_memory_allocation
      # Measure memory allocation using ObjectSpace
      initial_objects = ObjectSpace.count_objects[:T_HASH]
      yield
      final_objects = ObjectSpace.count_objects[:T_HASH]
      final_objects - initial_objects
    end
  end
end
