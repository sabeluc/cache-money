module Cash
  module Query
    class Abstract
      delegate :with_exclusive_scope, :get, :set, :table_name, :indices, :find_from_ids_without_cache, :cache_key, :columns_hash, :to => :@active_record

      def self.perform(*args)
        new(*args).perform
      end

      def initialize(active_record, options1, options2)
        @active_record, @options1, @options2 = active_record, options1, options2 || {}
      end

      def perform(find_options = {}, get_options = {})
        if cache_config = cacheable?(@options1, @options2, find_options)
          if range?
            index = cache_config[1]
            range, cache_keys = range_cache_keys(cache_config[1], cache_config[0])
            misses, missed_keys, hits = range_hit_or_miss(cache_keys, index, get_options)
            populate_range_cache_and_format_results(misses, missed_keys, hits, index)
          else
            cache_keys, index = cache_keys(cache_config[0]), cache_config[1]
            misses, missed_keys, objects = hit_or_miss(cache_keys, index, get_options)
            format_results(cache_keys, 
                choose_deserialized_objects_if_possible(missed_keys, cache_keys, misses, objects))
          end
        else
          uncacheable
        end
      end
      
      def populate_range_cache_and_format_results(misses, missed_keys, hits, index)
        return if missed_keys.empty?
        attribute = missed_keys.first.split('/')[-2]
        object_ids = hits.values.collect { |range_object| range_object.data }
        deserialized_objects = deserialize_objects(object_ids) + misses
        range_values = build_range_cache_values(index.arity, attribute, missed_keys,
                                                deserialized_objects)
        range_values.keys.each do |key|
          if (key =~ /\/\*+$/)
            set_left_branch(key, range_values[key], :ttl => index.ttl) 
          else
            set(key, RangeData.new(range_values[key]), :ttl => index.ttl)
          end
        end
        deserialized_objects
      end
      
      def set_left_branch(key, data, options)
        root = get(key)
        set(key, RangeData.new(data, root && root.parent), options)
        
        parent_key = key
        child_key = key[0...-1]
        while (child_key =~ /\/\*+$/)
          child_data = get(child_key)
          if child_data.nil?
            set(child_key, RangeData.new(nil, parent_key), options)
          elsif child_data.parent.nil?
            child_data.parent = parent_key
            set(child_key, child_data, options)
          else
            break
          end
          parent_key = child_key
          child_key = child_key[0...-1]
        end
      end
      
      def build_range_cache_values(arity, attribute, missed_keys, deserialized_objects)
        deserialized_objects.sort! { |a, b| a.send(attribute).to_i <=> b.send(attribute).to_i }
        missed_keys.each { |key| key.gsub!(/^.*?\//,'') }
        range_values = missed_keys.zip(Array.new(missed_keys.size) {[]}).to_hash
        missed_keys.each do |key|
          range = range_from_key(arity, key)
          deserialized_objects.collect do |obj|
            if range.include?(obj.send(attribute).to_i)
              range_values[key] << obj.id
            end
          end 
        end
        range_values
      end

      DESC = /DESC/i
      
      def order
        @order ||= begin
          if order_sql = @options1[:order] || @options2[:order]
            matched, table_name, column_name, direction = *(ORDER.match(order_sql))
            [column_name, direction =~ DESC ? :desc : :asc]
          else
            ['id', :asc]
          end
        end
      end

      def limit
        @limit ||= @options1[:limit] || @options2[:limit]
      end

      def offset
        @offset ||= @options1[:offset] || @options2[:offset] || 0
      end

      def calculation?
        false
      end
      
      def range?
        return @range unless @range.nil?
        @range = begin
          [@options1, @options2].each { |options| return unless safe_options_for_cache?(options) }
          conditions = @options1.merge(@options2)[:conditions]
          attribute_value_pairs_for_conditions(conditions).detect do |pair|
            pair.second.class == Range
          end ? true : false
        end
      end

      private
      def cacheable?(*optionss)
        optionss.each { |options| return unless safe_options_for_cache?(options) }
        partial_indices = optionss.collect do |options|
          attribute_value_pairs_for_conditions(options[:conditions])
        end
        return if partial_indices.include?(nil)
        attribute_value_pairs = partial_indices.sum.sort { |x, y| x[0] <=> y[0] }
        
        if index = indexed_on?(attribute_value_pairs.collect { |pair| pair[0] })
          if index.matches?(self)
            [attribute_value_pairs, index]
          end
        end
      end

      def hit_or_miss(cache_keys, index, options)
        misses, missed_keys = nil, nil
        objects = @active_record.get(cache_keys, options.merge(:ttl => index.ttl)) do |missed_keys|
          misses = miss(missed_keys, @options1.merge(:limit => index.window))
          serialize_objects(index, misses)
        end
        [misses, missed_keys, objects]
      end
      
      def range_hit_or_miss(cache_keys, index, options)
        misses, missed_keys = [], []
        find_options = @options1.merge(:limit => index.window)
        hits = @active_record.get(cache_keys, options.merge(:ttl => index.ttl, 
            :arity => index.arity)) do |missed_keys|
          misses = find_range_from_keys(index.arity, missed_keys, find_options)
        end
        missed_keys.each { |key| hits.delete(key) }
        additional_missed_keys = remove_left_branch_from_hits(hits)
        misses += find_range_from_keys(index.arity, additional_missed_keys, find_options)
        [misses, missed_keys + additional_missed_keys, hits]
      end

      def remove_left_branch_from_hits(hits)
        left_branch = hits.keys.select { |key| key =~ /^.*?\/\*+$/ }
        missed_keys = []
        unless left_branch.empty?
          left_branch.each do |key|
            if hits[key].data.nil? 
              hits.delete(key)
              missed_keys << String.new(key)
            end
          end
        end
        return missed_keys
      end
      
      def cache_keys(attribute_value_pairs)
        attribute_value_pairs.flatten.join('/')
      end
      
      def range_cache_keys(index, attribute_value_pairs)
        attribute = attribute_value_pairs.first.first
        value = attribute_value_pairs.first.second
        last = value.last
        keys = []
        while (last >= value.first)
          key, last = largest_matching_range_key(index.arity, value, last)
          keys << key
        end
        return value, keys.collect { |key| attribute + "/" + key }
      end
      
      def largest_matching_range_key(arity, range, value)
        largest_digit = (arity - 1).to_s
        value.to_s(arity) =~ /(\d*?)(#{largest_digit}*)$/
        leading_digits, trailing_digits = $1, $2
        while (!range.include?(value - trailing_digits.to_i(arity)))
          leading_digits += (arity - 1).to_s(arity)
          trailing_digits = trailing_digits[0..-2]
        end
        key = leading_digits + trailing_digits.gsub(largest_digit, '*')
        return key, value - (trailing_digits.to_i(arity) + 1)
      end

      def safe_options_for_cache?(options)
        return false unless options.kind_of?(Hash)
        options.except(:conditions, :readonly, :limit, :offset, :order).values.compact.empty? && !options[:readonly]
      end
      
      def attribute_value_pairs_for_conditions(conditions)
        case conditions
        when Hash
          conditions.to_a.collect { |key, value| [key.to_s, value] }
        when String
          parse_indices_from_condition(conditions)
        when Array
          parse_indices_from_condition(*conditions)
        when NilClass
          []
        end
      end

      AND = /\s+AND\s+/i
      TABLE_AND_COLUMN = /(?:(?:`|")?(\w+)(?:`|")?\.)?(?:`|")?(\w+)(?:`|")?/              # Matches: `users`.id, `users`.`id`, users.id, id
      VALUE = /'?(\d+|\?|(?:(?:[^']|'')*))'?/                     # Matches: 123, ?, '123', '12''3'
      KEY_EQ_VALUE = /^\(?#{TABLE_AND_COLUMN}\s+=\s+#{VALUE}\)?$/ # Matches: KEY = VALUE, (KEY = VALUE)
      ORDER = /^#{TABLE_AND_COLUMN}\s*(ASC|DESC)?$/i              # Matches: COLUMN ASC, COLUMN DESC, COLUMN

      def parse_indices_from_condition(conditions = '', *values)
        values = values.dup
        conditions.split(AND).inject([]) do |indices, condition|
          matched, table_name, column_name, sql_value = *(KEY_EQ_VALUE.match(condition))
          if matched
            value = sql_value == '?' ? values.shift : columns_hash[column_name].type_cast(sql_value)
            indices << [column_name, value]
          else
            return nil
          end
        end
      end

      def indexed_on?(attributes)
        indices.detect { |index| index == attributes }
      end
      alias_method :index_for, :indexed_on?

      def format_results(cache_keys, objects)
        return objects if objects.blank?

        objects = convert_to_array(cache_keys, objects)
        objects = apply_limits_and_offsets(objects, @options1)
        deserialize_objects(objects)
      end

      def choose_deserialized_objects_if_possible(missed_keys, cache_keys, misses, objects)
        missed_keys == cache_keys ? misses : objects
      end

      def serialize_objects(index, objects)
        Array(objects).collect { |missed| index.serialize_object(missed) }
      end

      def convert_to_array(cache_keys, object)
        if object.kind_of?(Hash)
          cache_keys.collect { |key| object[cache_key(key)] }.flatten.compact
        else
          Array(object)
        end
      end

      def apply_limits_and_offsets(results, options)
        results.slice((options[:offset] || 0), (options[:limit] || results.length))
      end

      def deserialize_objects(objects)
        if objects.first.kind_of?(ActiveRecord::Base)
          objects
        else
          cache_keys = objects.collect { |id| "id/#{id}" }
          objects = get(cache_keys, &method(:find_from_keys))
          convert_to_array(cache_keys, objects)
        end
      end

      def find_from_keys(*missing_keys)
        missing_ids = Array(missing_keys).flatten.collect { |key| key.split('/')[2].to_i }
        find_from_ids_without_cache(missing_ids, {})
      end
            
      def key_from_range(arity, range) 
        key = ""
        low, high = range.first.to_s(arity).split(//), range.last.to_s(arity).split(//)
        high.each_with_index { |digit, index| (digit == low[index]) ? key += digit : key += "*" }
        key
      end
      
      def range_from_key(arity, key)
        range_key = key.split('/').last
        high = (arity - 1).to_s
        range = Range.new(range_key.gsub("*", "0").to_i(arity), range_key.gsub("*", high).to_i(arity))
      end
      
      def find_range_from_keys(arity, missing_keys, options)
        return [] if missing_keys.empty?
        range_attr = missing_keys.first.split('/')[-2]
        missing_objects = missing_keys.collect { |key| range_from_key(arity, key).to_a }.flatten
        find_every_without_cache(:conditions => { range_attr => missing_objects })
      end
    end
  end
end
