module Cash
  module Config
    def self.included(a_module)
      a_module.module_eval do
        extend ClassMethods
        delegate :repository, :to => "self.class"
      end
    end

    module ClassMethods
      def self.extended(a_class)
        class << a_class
          attr_reader :cache_config
          delegate :repository, :indices, :ranges, :to => :@cache_config
          alias_method_chain :inherited, :cache_config
        end
      end

      def inherited_with_cache_config(subclass)
        inherited_without_cache_config(subclass)
        @cache_config.inherit(subclass)
      end

      def index(attributes, options = {})
        options.assert_valid_keys(:ttl, :order, :limit, :buffer, :ranges, :arity)
        (@cache_config.indices.unshift(Index.new(@cache_config, self, attributes, options))).uniq!
      end
      
      def range(attribute, options = {})
        options.assert_valid_keys(:arity)
        index = @cache_config.indices.detect { |index| index == attribute.to_s }
        if index
          index.support_ranges!(options)
        else
          (@cache_config.indices.unshift(Index.new(@cache_config, self, attribute, 
              options.merge(:ranges => true)))).uniq!
        end
      end

      def version(number)
        @cache_config.options[:version] = number
      end

      def cache_config=(config)
        @cache_config = config
      end
    end

    class Config
      attr_reader :active_record, :options

      def self.create(active_record, options, indices = [])
        active_record.cache_config = new(active_record, options)
        indices.each { |i| active_record.index i.attributes, i.options }
      end

      def initialize(active_record, options = {})
        @active_record, @options = active_record, options
      end

      def repository
        @options[:repository]
      end

      def ttl
        @options[:ttl]
      end
      
      def arity
        @options[:arity]
      end

      def version
        @options[:version] || 1
      end

      def indices
        @indices ||= active_record == ActiveRecord::Base ? [] : [Index.new(self, active_record, active_record.primary_key)]
      end
      
      def inherit(active_record)
        self.class.create(active_record, @options, indices)
      end
    end
  end
end
