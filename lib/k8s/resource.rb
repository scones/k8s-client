# frozen_string_literal: true

require 'recursive-open-struct'
require 'hashdiff'
require 'yaml/safe_load_stream'

module K8s
  # generic untyped resource
  class Resource < RecursiveOpenStruct
    using YAMLSafeLoadStream
    using K8s::Util::HashBackport if RUBY_VERSION < "2.5"

    include Comparable

    # @param data [String]
    # @return [self]
    def self.from_json(data)
      new(K8s::JSONParser.parse(data))
    end

    # @param filename [String] file path
    # @return [K8s::Resource]
    def self.from_file(filename)
      new(YAML.safe_load(File.read(filename)))
    end

    # @param path [String] file path
    # @return [Array<K8s::Resource>]
    def self.from_files(path)
      stat = File.stat(path)

      if stat.directory?
        # recurse
        Dir.glob("#{path}/*.{yml,yaml}").sort.map { |dir| from_files(dir) }.flatten
      else
        yaml = File.read(path)
        hash = YAML.safe_load_stream(yaml, path)
        hash.map{|doc| new(doc) }
        #YAML.safe_load_stream(File.read(path), path).map{ |doc| new(doc) }
      end
    end

    def self.default_options
      {
        mutate_input_hash: false,
        recurse_over_arrays: true,
        preserve_original_keys: false
      }
    end

    # @param hash [Hash]
    # @param recurse_over_arrays [Boolean]
    # @param options [Hash] see RecursiveOpenStruct#initialize
    def initialize hash, options = {}
      super(
        hash.is_a?(Hash) ? hash : hash.to_h,
        options
      )
    end

    def <=>(other)
      to_h <=> (other.is_a?(Hash) ? other : other.to_h)
    end

    # @param options [Hash] see Hash#to_json
    # @return [String]
    def to_json(options = {})
      to_h.to_json(options)
    end

    # merge in fields
    #
    # @param attrs [Hash, K8s::Resource]
    # @return [K8s::Resource]
    def merge(attrs)
      self.class.new(
        Util.deep_merge(to_hash, attrs.to_hash, overwrite_arrays: true, merge_nil_values: true)
      )
    end

    # @return [String]
    def checksum
      @checksum ||= Digest::MD5.hexdigest(Marshal.dump(to_h))
    end

    # @param attrs [Hash]
    # @param config_annotation [String]
    # @return [Hash]
    def merge_patch_ops(attrs, config_annotation)
      Util.json_patch(current_config(config_annotation), Util.deep_transform_keys(attrs, :to_s))
    end

    # Gets the existing resources (on kube api) configuration, an empty hash if not present
    #
    # @param config_annotation [String]
    # @return [Hash]
    def current_config(config_annotation)
      current_cfg = metadata.annotations&.dig(config_annotation)
      return {} unless current_cfg

      current_hash = K8s::JSONParser.parse(current_cfg)
      # kubectl adds empty metadata.namespace, let's fix it
      current_hash['metadata'].delete('namespace') if current_hash.dig('metadata', 'namespace').to_s.empty?

      current_hash
    end

    # @param config_annotation [String]
    # @return [Boolean]
    def can_patch?(config_annotation)
      !!metadata.annotations&.dig(config_annotation)
    end
  end
end
