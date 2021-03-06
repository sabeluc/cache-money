module Cash
  class Index
    attr_reader :attributes, :options
    delegate :each, :hash, :to => :@attributes
    delegate :get, :set, :expire, :find_every_without_cache, :calculate_without_cache, :calculate_with_cache, :incr, :decr, :primary_key, :to => :@active_record

    DEFAULT_OPTIONS = { :ttl => 1.day, :ranges => false, :arity => 10 }

    def initialize(config, active_record, attributes, options = {})
      @config, @active_record, @attributes, @options = config, active_record, Array(attributes).collect(&:to_s).sort, DEFAULT_OPTIONS.merge(options)
    end

    def ==(other)
      case other
      when Index
        attributes == other.attributes
      else
        attributes == Array(other)
      end
    end
    alias_method :eql?, :==

    module Commands
      def add(object)
        clone = object.shallow_clone
        _, new_attribute_value_pairs = old_and_new_attribute_value_pairs(object)
        add_to_index_with_minimal_network_operations(new_attribute_value_pairs, clone)
      end

      def update(object)
        clone = object.shallow_clone
        old_attribute_value_pairs, new_attribute_value_pairs = old_and_new_attribute_value_pairs(object)
        update_index_with_minimal_network_operations(old_attribute_value_pairs, new_attribute_value_pairs, clone)
      end

      def remove(object)
        old_attribute_value_pairs, _ = old_and_new_attribute_value_pairs(object)
        remove_from_index_with_minimal_network_operations(old_attribute_value_pairs, object)
      end

      def delete(object)
        old_attribute_value_pairs, _ = old_and_new_attribute_value_pairs(object)
        key = cache_key(old_attribute_value_pairs)
        expire(key)
      end
    end
    include Commands

    module Attributes
      def ttl
        @ttl ||= options[:ttl] || config.ttl
      end

      def order
        @order ||= options[:order] || :asc
      end

      def limit
        options[:limit]
      end

      def buffer
        options[:buffer]
      end

      def window
        limit && limit + buffer
      end
      
      def supports_ranges?
        options[:ranges]
      end
      
      def arity
        options[:arity]
      end
      
      def arity=(value)
        options[:arity] = value
      end
      
      def support_ranges!(options)
        options[:ranges] = true
        @options.merge!(options) if options
      end
    end
    include Attributes

    def serialize_object(object)
      primary_key? ? object : object.id
    end

    def matches?(query)
      return false if query.range? && !supports_ranges?
      return true if query.calculation?
      (query.order == ['id', order] &&
          (!limit || (query.limit && query.limit + query.offset <= limit)))
    end

    private
    def old_and_new_attribute_value_pairs(object)
      old_attribute_value_pairs = []
      new_attribute_value_pairs = []
      @attributes.each do |name|
        new_value = object.attributes[name]
        original_value = object.send("#{name}_was")
        old_attribute_value_pairs << [name, original_value]
        new_attribute_value_pairs << [name, new_value]
      end
      [old_attribute_value_pairs, new_attribute_value_pairs]
    end

    def add_to_index_with_minimal_network_operations(attribute_value_pairs, object)
      if primary_key?
        add_object_to_primary_key_cache(attribute_value_pairs, object)
      elsif supports_ranges?
        add_object_to_range_cache(attribute_value_pairs, object)
      else
        add_object_to_cache(attribute_value_pairs, object)
      end
    end

    def primary_key?
      @attributes.size == 1 && @attributes.first == primary_key
    end
    
    def add_object_to_primary_key_cache(attribute_value_pairs, object)
      set(cache_key(attribute_value_pairs), [object], :ttl => ttl)
    end

    def cache_key(attribute_value_pairs)
      attribute_value_pairs.flatten.join('/')
    end

    def add_object_to_cache(attribute_value_pairs, object, overwrite = true)
      return if invalid_cache_key?(attribute_value_pairs)

      key, cache_value, cache_hit = get_key_and_value_at_index(attribute_value_pairs)
      if !cache_hit || overwrite
        object_to_add = serialize_object(object)
        objects = (cache_value + [object_to_add]).sort do |a, b|
          (a <=> b) * (order == :asc ? 1 : -1)
        end.uniq
        objects = truncate_if_necessary(objects)
        set(key, objects, :ttl => ttl)
        incr("#{key}/count") { calculate_at_index(:count, attribute_value_pairs) }
      end
    end
    
    def add_object_to_range_cache(attribute_value_pairs, object)
      raise if attribute_value_pairs.size > 1
      object_to_add = serialize_object(object)
      keys = range_cache_keys(attribute_value_pairs.first)
      keys.each do |key|
        # Do not add individual objects to empty range entries that should
        # contain collections, e.g. attr/1**.
        cache_value = get(key)
        next if cache_value.nil? && key =~ /\*/
        if cache_value && cache_value.parent
          keys.push(cache_value.parent)
          next if cache_value.data.nil?
        end

        cached_objects = cache_value ? cache_value.data : []
        objects = (cached_objects + [object_to_add]).sort do |a, b|
          (a <=> b) * (order == :asc ? 1 : -1)
        end.uniq
        set(key, RangeData.new(objects), :ttl => ttl)
      end
    end
    
    def remove_object_from_range_cache(attribute_value_pairs, object)
      raise if attribute_value_pairs.size > 1 
      object_to_remove = serialize_object(object)
      keys = range_cache_keys(attribute_value_pairs.first)
      keys.each do |key|
        cache_value = get(key)
        next if cache_value.nil?
        if cache_value.parent
          keys.push(cache_value.parent)
          next if cache_value.data.nil?
        end
        objects = cache_value.data - [object_to_remove]
        set(key, RangeData.new(objects, cache_value.parent), :ttl => ttl)
      end
    end
    
    def range_cache_keys(attribute_value_pair)
      att = attribute_value_pair.first.to_s
      keys, value = [], attribute_value_pair.second.to_i.to_s(arity)
      (value.size + 1).times { |i| keys << att + "/" + value[0...i] + '*' * (value.size - i) }
      keys
    end

    def invalid_cache_key?(attribute_value_pairs)
      attribute_value_pairs.collect { |_,value| value }.any? { |x| x.nil? }
    end

    def get_key_and_value_at_index(attribute_value_pairs)
      key = cache_key(attribute_value_pairs)
      cache_hit = true
      cache_value = get(key) do
        cache_hit = false
        conditions = attribute_value_pairs.to_hash
        find_every_without_cache(:select => primary_key, :conditions => conditions, :limit => window).collect do |object|
          serialize_object(object)
        end
      end
      [key, cache_value, cache_hit]
    end

    def truncate_if_necessary(objects)
      objects.slice(0, window || objects.size)
    end

    def calculate_at_index(operation, attribute_value_pairs)
      conditions = attribute_value_pairs.to_hash
      calculate_without_cache(operation, :all, :conditions => conditions)
    end

    def update_index_with_minimal_network_operations(old_attribute_value_pairs, new_attribute_value_pairs, object)
      if index_is_stale?(old_attribute_value_pairs, new_attribute_value_pairs)
        if supports_ranges?
          remove_object_from_range_cache(old_attribute_value_pairs, object)
          add_object_to_range_cache(new_attribute_value_pairs, object)          
        else
          remove_object_from_cache(old_attribute_value_pairs, object)
          add_object_to_cache(new_attribute_value_pairs, object)
        end
      elsif primary_key?
        add_object_to_primary_key_cache(new_attribute_value_pairs, object)
      else
        add_object_to_cache(new_attribute_value_pairs, object, false)
      end
    end
    
    def index_is_stale?(old_attribute_value_pairs, new_attribute_value_pairs)
      old_attribute_value_pairs != new_attribute_value_pairs
    end
    
    def remove_from_index_with_minimal_network_operations(attribute_value_pairs, object)
      if primary_key?
        remove_object_from_primary_key_cache(attribute_value_pairs, object)
      elsif supports_ranges?
        remove_object_from_range_cache(attribute_value_pairs, object)
      else
        remove_object_from_cache(attribute_value_pairs, object)
      end
    end

    def remove_object_from_primary_key_cache(attribute_value_pairs, object)
      set(cache_key(attribute_value_pairs), [], :ttl => ttl)
    end

    def remove_object_from_cache(attribute_value_pairs, object)
      return if invalid_cache_key?(attribute_value_pairs)
      key, cache_value, _ = get_key_and_value_at_index(attribute_value_pairs)
      object_to_remove = serialize_object(object)
      objects = cache_value - [object_to_remove]
      objects = resize_if_necessary(attribute_value_pairs, objects)
      set(key, objects, :ttl => ttl)
    end
    
    def resize_if_necessary(attribute_value_pairs, objects)
      conditions = attribute_value_pairs.to_hash
      key = cache_key(attribute_value_pairs)
      count = decr("#{key}/count") { calculate_at_index(:count, attribute_value_pairs) }

      if limit && objects.size < limit && objects.size < count
        find_every_without_cache(:select => :id, :conditions => conditions).collect do |object|
          serialize_object(object)
        end
      else
        objects
      end
    end
  end
end
