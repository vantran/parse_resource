require "rubygems"
require "bundler/setup"
require "active_model"
require "erb"
require "rest-client"
require "json"
require "active_support/hash_with_indifferent_access"
require "parse_resource/query"
require "parse_resource/query_methods"
require "parse_resource/parse_error"
require "parse_resource/parse_exceptions"
require "parse_resource/types/parse_geopoint"

module ParseResource
  

  class Base
    # ParseResource::Base provides an easy way to use Ruby to interace with a Parse.com backend
    # Usage:
    #  class Post < ParseResource::Base
    #    fields :title, :author, :body
    #  end

    include ActiveModel::Validations
    include ActiveModel::Conversion
    include ActiveModel::AttributeMethods
    extend ActiveModel::Naming
    extend ActiveModel::Callbacks
    HashWithIndifferentAccess = ActiveSupport::HashWithIndifferentAccess

    define_model_callbacks :save, :create, :update, :destroy
    
    # Instantiates a ParseResource::Base object
    #
    # @params [Hash], [Boolean] a `Hash` of attributes and a `Boolean` that should be false only if the object already exists
    # @return [ParseResource::Base] an object that subclasses `Parseresource::Base`
    def initialize(attributes = {}, new=true)
      #attributes = HashWithIndifferentAccess.new(attributes)

      if new
        @unsaved_attributes = attributes
        @unsaved_attributes.stringify_keys!
      else
        @unsaved_attributes = {}
      end
      self.attributes = {}
            
      self.attributes.merge!(attributes)
      self.attributes unless self.attributes.empty?
      create_setters_and_getters!
    end

    # Explicitly adds a field to the model.
    #
    # @param [Symbol] name the name of the field, eg `:author`.
    # @param [Boolean] val the return value of the field. Only use this within the class.
    def self.field(fname, val=nil)
      fname = fname.to_sym
      class_eval do
        define_method(fname) do
          get_attribute("#{fname}")
        end
      end
      unless self.respond_to? "#{fname}="
        class_eval do
          define_method("#{fname}=") do |val|
            set_attribute("#{fname}", val)
            
            val
          end
        end
      end
    end

    # Add multiple fields in one line. Same as `#field`, but accepts multiple args.
    #
    # @param [Array] *args an array of `Symbol`s, `eg :author, :body, :title`.
    def self.fields(*args)
      args.each {|f| field(f)}
    end
    
    # Similar to its ActiveRecord counterpart.
    #
    # @param [Hash] options Added so that you can specify :class_name => '...'. It does nothing at all, but helps you write self-documenting code.
    def self.belongs_to(parent, options = {})
      field(parent)
    end
    
    def to_pointer
      klass_name = self.class.model_name
      klass_name = "_User" if klass_name == "User"
      klass_name = "_Installation" if klass_name == "Installation"
      {"__type" => "Pointer", "className" => klass_name, "objectId" => self.id}
    end

    def self.to_date_object(date)
      {"__type" => "Date", "iso" => date.iso8601} if date && (date.is_a?(Date) || date.is_a?(DateTime) || date.is_a?(Time))
    end

    # Creates setter methods for model fields
    def create_setters!(k,v)
      unless self.respond_to? "#{k}="
        self.class.send(:define_method, "#{k}=") do |val|
          set_attribute("#{k}", val)
          
          val
        end
      end
    end

    def self.method_missing(method_name, *args)
      method_name = method_name.to_s
      if method_name.start_with?("find_by_")
        attrib   = method_name.gsub(/^find_by_/,"")
        finder_name = "find_all_by_#{attrib}"

        define_singleton_method(finder_name) do |target_value|
          where({attrib.to_sym => target_value}).first
        end

        send(finder_name, args[0])

      elsif method_name.start_with?("find_all_by_")
        attrib   = method_name.gsub(/^find_all_by_/,"")
        finder_name = "find_all_by_#{attrib}"

        define_singleton_method(finder_name) do |target_value|
          where({attrib.to_sym => target_value}).all
        end

        send(finder_name, args[0])
      else
        super(method_name.to_sym, *args)
      end
    end

    # Creates getter methods for model fields
    def create_getters!(k,v)
      unless self.respond_to? "#{k}"
        self.class.send(:define_method, "#{k}") do
          get_attribute("#{k}")
        end
      end
    end

    def create_setters_and_getters!
      @attributes.each_pair do |k,v|
        create_setters!(k,v)
        create_getters!(k,v)
      end
    end

    @@settings ||= nil

    # Explicitly set Parse.com API keys.
    #
    # @param [String] app_id the Application ID of your Parse database
    # @param [String] master_key the Master Key of your Parse database
    def self.load!(app_id, master_key)
      @@settings = {"app_id" => app_id, "master_key" => master_key}
    end

    def self.settings
      if @@settings.nil?
        path = "config/parse_resource.yml"
        #environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
        environment = ENV["RACK_ENV"]
        @@settings = YAML.load(ERB.new(File.new(path).read).result)[environment]
      end
      @@settings
    end

    # Creates a RESTful resource
    # sends requests to [base_uri]/[classname]
    #
    def self.resource
      if @@settings.nil?
        path = "config/parse_resource.yml"
        environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
        @@settings = YAML.load(ERB.new(File.new(path).read).result)[environment]
      end

      if model_name == "User" #https://parse.com/docs/rest#users-signup
        base_uri = "https://api.parse.com/1/users"
      elsif model_name == "Installation" #https://parse.com/docs/rest#installations
        base_uri = "https://api.parse.com/1/installations"
      else
        base_uri = "https://api.parse.com/1/classes/#{model_name}"
      end

      #refactor to settings['app_id'] etc
      app_id     = @@settings['app_id']
      master_key = @@settings['master_key']
      RestClient::Resource.new(base_uri, app_id, master_key)
    end

    # Creates a RESTful resource for file uploads
    # sends requests to [base_uri]/files
    #
    def self.upload(file_instance, filename, options={})
      if @@settings.nil?
        path = "config/parse_resource.yml"
        environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
        @@settings = YAML.load(ERB.new(File.new(path).read).result)[environment]
      end

      base_uri = "https://api.parse.com/1/files"
      
      #refactor to settings['app_id'] etc
      app_id     = @@settings['app_id']
      master_key = @@settings['master_key']

      options[:content_type] ||= 'image/jpg' # TODO: Guess mime type here.
      file_instance = File.new(file_instance, 'rb') if file_instance.is_a? String

      filename = filename.parameterize

      private_resource = RestClient::Resource.new "#{base_uri}/#{filename}", app_id, master_key
      private_resource.post(file_instance, options) do |resp, req, res, &block|
        return false if resp.code == 400
        return JSON.parse(resp) rescue {"code" => 0, "error" => "unknown error"}
      end
      false
    end

    # Find a ParseResource::Base object by ID
    #
    # @param [String] id the ID of the Parse object you want to find.
    # @return [ParseResource] an object that subclasses ParseResource.
    def self.find(id)
			raise RecordNotFound if id.blank?
      where(:objectId => id).first
    end

    # Find a ParseResource::Base object by chaining #where method calls.
    #
    def self.where(*args)
      Query.new(self).where(*args)
    end
    

    include ParseResource::QueryMethods


    # Create a ParseResource::Base object.
    #
    # @param [Hash] attributes a `Hash` of attributes
    # @return [ParseResource] an object that subclasses `ParseResource`. Or returns `false` if object fails to save.
    def self.create(attributes = {})
      attributes = HashWithIndifferentAccess.new(attributes)
      obj = new(attributes)
      obj.save
      obj # This won't return true/false it will return object or nil...
    end

    def self.destroy_all
      all.each do |object|
        object.destroy
      end
    end

    def self.class_attributes
      @class_attributes ||= {}
    end

    def persisted?
      if id
        true
      else
        false
      end
    end

    def new?
      !persisted?
    end

    # delegate from Class method
    def resource
      self.class.resource
    end

    # create RESTful resource for the specific Parse object
    # sends requests to [base_uri]/[classname]/[objectId]
    def instance_resource
      self.class.resource["#{self.id}"]
    end

    def create
      run_callbacks :create do
        opts = {:content_type => "application/json"}
        attrs = @unsaved_attributes.to_json
        self.resource.post(attrs, opts) do |resp, req, res, &block|
          if resp.code == 200 || resp.code == 201
            @attributes.merge!(JSON.parse(resp))
            @attributes.merge!(@unsaved_attributes)
            attributes = HashWithIndifferentAccess.new(attributes)
            @unsaved_attributes = {}
            create_setters_and_getters!
            return true
          else
            error_response = JSON.parse(resp)
            pe = ParseError.new(resp.code.to_s, error_response).to_array
            self.errors.add(pe[0], pe[1])
            return false
          end
        end
      end
    end

    def save
      if valid?
        run_callbacks :save do
          if new?
            return create
          else
            return update
          end
        end
      else
        false
      end
      rescue false
    end

    def update(attributes = {})

      attributes = HashWithIndifferentAccess.new(attributes)

      @unsaved_attributes.merge!(attributes)

      put_attrs = @unsaved_attributes
      put_attrs.delete('objectId')
      put_attrs.delete('createdAt')
      put_attrs.delete('updatedAt')
      put_attrs = put_attrs.to_json
      
      opts = {:content_type => "application/json"}
      result = self.instance_resource.put(put_attrs, opts) do |resp, req, res, &block|
        if resp.code == 200 || resp.code == 201
          @attributes.merge!(JSON.parse(resp))
          @attributes.merge!(@unsaved_attributes)
          @unsaved_attributes = {}
          create_setters_and_getters!
          return true
        else
          error_response = JSON.parse(resp)
          pe = ParseError.new(resp.code.to_s, error_response).to_array
          self.errors.add(pe[0], pe[1])        
          return false
        end
      end
    end

    def update_attributes(attributes = {})
      self.update(attributes)
    end

    def destroy
      if self.instance_resource.delete
        @attributes = {}
        @unsaved_attributes = {}
        return true
      end
      false
    end

    def reload
      return false if new?
      
      fresh_object = self.class.find(id)
      @attributes.update(fresh_object.instance_variable_get('@attributes'))
      @unsaved_attributes = {}
      
      self
    end

    # provides access to @attributes for getting and setting
    def attributes
      @attributes ||= self.class.class_attributes
      @attributes
    end

    # AKN 2012-06-18: Shouldn't this also be setting @unsaved_attributes?
    def attributes=(n)
      @attributes = n
      @attributes
    end

    def get_attribute(k)
      attrs = @unsaved_attributes[k.to_s] ? @unsaved_attributes : @attributes
      case attrs[k]
      when Hash
        klass_name = attrs[k]["className"]
        klass_name = "User" if klass_name == "_User"
        klass_name = "Installation" if klass_name == "_Installation"
        case attrs[k]["__type"]
        when "Pointer"
          result = klass_name.constantize.find(attrs[k]["objectId"])
        when "Object"
          result = klass_name.constantize.new(attrs[k], false)
        when "Date"
          result = DateTime.parse(attrs[k]["iso"])
        when "File"
          result = attrs[k]["url"]
        when "GeoPoint"
          result = ParseGeoPoint.new(attrs[k])
        end #todo: support other types https://www.parse.com/docs/rest#objects-types
      else
        result =  attrs["#{k}"]
      end          
      result
    end

    def set_attribute(k, v)
      if v.is_a?(Date) || v.is_a?(Time) || v.is_a?(DateTime)
        v = {"__type" => "Date", "iso" => v.iso8601}
      elsif v.respond_to?(:to_pointer)
        v = v.to_pointer 
      end
      @unsaved_attributes[k.to_s] = v unless v == @attributes[k.to_s] # || @unsaved_attributes[k.to_s]
      @attributes[k.to_s] = v
      v
    end


    # aliasing for idiomatic Ruby
    def id; get_attribute("objectId") rescue nil; end
    def objectId; get_attribute("objectId") rescue nil; end

    def created_at; self.createdAt; end

    def updated_at; self.updatedAt rescue nil; end

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
    end

  end
end
