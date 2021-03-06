
require "logstash/namespace"
require "logstash/config/registry"
require "logstash/logging"
require "logstash/util/password"
require "logstash/version"
require "i18n"

# This module is meant as a mixin to classes wishing to be configurable from
# config files
#
# The idea is that you can do this:
#
# class Foo < LogStash::Config
#   # Add config file settings
#   config "path" => ...
#   config "tag" => ...
#
#   # Add global flags (becomes --foo-bar)
#   flag "bar" => ...
# end
#
# And the config file should let you do:
#
# foo {
#   "path" => ...
#   "tag" => ...
# }
#
module LogStash::Config::Mixin
  attr_accessor :config

  CONFIGSORT = {
    Symbol => 0,
    String => 0,
    Regexp => 100,
  }

  # This method is called when someone does 'include LogStash::Config'
  def self.included(base)
    # Add the DSL methods to the 'base' given.
    base.extend(LogStash::Config::Mixin::DSL)
  end

  def config_init(params)
    # Validation will modify the values inside params if necessary.
    # For example: converting a string to a number, etc.
    
    # store the plugin type, turns LogStash::Inputs::Base into 'input'
    @plugin_type = self.class.ancestors[1].name.split("::")[1].downcase.gsub(/s$/,"")
    if !self.class.validate(params)
      raise LogStash::Plugin::ConfigurationError,
        I18n.t("logstash.agent.configuration.invalid_plugin_settings")
    end

    # warn about deprecated variable use
    params.each do |name, value|
      opts = self.class.get_config[name]
      if opts && opts[:deprecated]
        @logger.warn("Deprecated config item #{name.inspect} set " +
                     "in #{self.class.name}", :name => name, :plugin => self)
      end
    end

    # Set defaults from 'config :foo, :default => somevalue'
    self.class.get_config.each do |name, opts|
      next if params.include?(name.to_s)
      if opts.include?(:default) and (name.is_a?(Symbol) or name.is_a?(String))
        if opts[:validate] == :password
          @logger.debug("Converting default value in #{self.class.name} (#{name}) to password object")
          params[name.to_s] = ::LogStash::Util::Password.new(opts[:default])
        else
          default = opts[:default]
          if default.is_a?(Array) or default.is_a?(Hash)
            default = default.clone
          end
          params[name.to_s] = default
        end
      end
    end

    # set instance variables like '@foo'  for each config value given.
    params.each do |key, value|
      next if key[0, 1] == "@"

      # Set this key as an instance variable only if it doesn't start with an '@'
      @logger.debug("config #{self.class.name}/@#{key} = #{value.inspect}")
      instance_variable_set("@#{key}", value)
    end

    @config = params
  end # def config_init

  module DSL
    attr_accessor :flags

    # If name is given, set the name and return it.
    # If no name given (nil), return the current name.
    def config_name(name=nil)
      @config_name = name if !name.nil?
      LogStash::Config::Registry.registry[@config_name] = self
      return @config_name
    end

    def plugin_status(status=nil)
      @plugin_status = status if !status.nil?
      return @plugin_status
    end

    # Define a new configuration setting
    def config(name, opts={})
      @config ||= Hash.new
      # TODO(sissel): verify 'name' is of type String, Symbol, or Regexp

      name = name.to_s if name.is_a?(Symbol)
      @config[name] = opts  # ok if this is empty

      if name.is_a?(String)
        define_method(name) { instance_variable_get("@#{name}") }
        define_method("#{name}=") { |v| instance_variable_set("@#{name}", v) }
      end
    end # def config

    def get_config
      return @config
    end # def get_config

    # Define a flag 
    def flag(*args, &block)
      @flags ||= []

      @flags << {
        :args => args,
        :block => block
      }
    end # def flag

    def options(opts)
      # add any options from this class
      prefix = self.name.split("::").last.downcase
      @flags.each do |flag|
        flagpart = flag[:args].first.gsub(/^--/,"")
        # TODO(sissel): logger things here could help debugging.

        opts.on("--#{prefix}-#{flagpart}", *flag[:args][1..-1], &flag[:block])
      end
    end # def options

    # This is called whenever someone subclasses a class that has this mixin.
    def inherited(subclass)
      # Copy our parent's config to a subclass.
      # This method is invoked whenever someone subclasses us, like:
      # class Foo < Bar ...
      subconfig = Hash.new
      if !@config.nil?
        @config.each do |key, val|
          subconfig[key] = val
        end
      end
      subclass.instance_variable_set("@config", subconfig)
    end # def inherited

    def validate(params)
      @plugin_name = config_name #[superclass.config_name, config_name].join("/")
      @plugin_type = superclass.config_name
      @logger = Cabin::Channel.get(LogStash)
      is_valid = true

      is_valid &&= validate_plugin_status
      is_valid &&= validate_check_invalid_parameter_names(params)
      is_valid &&= validate_check_required_parameter_names(params)
      is_valid &&= validate_check_parameter_values(params)

      return is_valid
    end # def validate

    def validate_plugin_status
      docmsg = "For more information about plugin statuses, see http://logstash.net/docs/#{LOGSTASH_VERSION}/plugin-status "
      case @plugin_status
      when "unsupported"
        @logger.warn("Using unsupported plugin '#{@config_name}'. This plugin isn't well supported by the community and likely has no maintainer. #{docmsg}")
      when "experimental"
        @logger.warn("Using experimental plugin '#{@config_name}'. This plugin is untested and may change in the future. #{docmsg}")
      when "beta"
        @logger.info("Using beta plugin '#{@config_name}'. #{docmsg}")
      when "stable"
        # This is cool. Nothing worth logging.
      when nil
        raise "#{@config_name} must set a plugin_status. #{docmsg}"
      else
        raise "#{@config_name} set an invalid plugin status #{@plugin_status}. Valid values are unsupported, experimental, beta and stable. #{docmsg}"
      end
      return true
    end

    def validate_check_invalid_parameter_names(params)
      invalid_params = params.keys
      # Filter out parameters that match regexp keys.
      # These are defined in plugins like this:
      #   config /foo.*/ => ...
      @config.each_key do |config_key|
        if config_key.is_a?(Regexp)
          invalid_params.reject! { |k| k =~ config_key }
        elsif config_key.is_a?(String)
          invalid_params.reject! { |k| k == config_key }
        end
      end

      if invalid_params.size > 0
        invalid_params.each do |name|
          @logger.error("Unknown setting '#{name}' for #{@plugin_name}")
        end
        return false
      end # if invalid_params.size > 0
      return true
    end # def validate_check_invalid_parameter_names

    def validate_check_required_parameter_names(params)
      is_valid = true

      @config.each do |config_key, config|
        next unless config[:required]

        if config_key.is_a?(Regexp)
          next if params.keys.select { |k| k =~ config_key }.length > 0
        elsif config_key.is_a?(String)
          next if params.keys.member?(config_key)
        end
        @logger.error(I18n.t("logstash.agent.configuration.setting_missing",
                             :setting => config_key, :plugin => @plugin_name,
                             :type => @plugin_type))
        is_valid = false
      end

      return is_valid
    end

    def validate_check_parameter_values(params)
      # Filter out parametrs that match regexp keys.
      # These are defined in plugins like this:
      #   config /foo.*/ => ... 
      is_valid = true

      # string/symbols are first, then regexes.
      config_keys = @config.keys.sort do |a,b|
        CONFIGSORT[a.class] <=> CONFIGSORT[b.class] 
      end
      #puts "Key order: #{config_keys.inspect}"
      #puts @config.keys.inspect

      params.each do |key, value|
        config_keys.each do |config_key|
          #puts
          #puts "Candidate: #{key.inspect} / #{value.inspect}"
          #puts "Config: #{config_key} / #{config_val} "
          next unless (config_key.is_a?(Regexp) && key =~ config_key) \
                      || (config_key.is_a?(String) && key == config_key)
          config_val = @config[config_key][:validate]
          #puts "  Key matches."
          success, result = validate_value(value, config_val)
          if success 
            # Accept coerced value if success
            # Used for converting values in the config to proper objects.
            params[key] = result if !result.nil?
          else
            @logger.error(I18n.t("logstash.agent.configuration.setting_invalid",
                                 :plugin => @plugin_name, :type => @plugin_type,
                                 :value => value, :value_type => config_val))
          end
          #puts "Result: #{key} / #{result.inspect} / #{success}"
          is_valid &&= success

          break # done with this param key
        end # config.each
      end # params.each

      return is_valid
    end # def validate_check_parameter_values

    def validator_find(key)
      @config.each do |config_key, config_val|
        if (config_key.is_a?(Regexp) && key =~ config_key) \
           || (config_key.is_a?(String) && key == config_key)
          return config_val
        end
      end # @config.each
      return nil
    end

    def validate_value(value, validator)
      # Validator comes from the 'config' pieces of plugins.
      # They look like this
      #   config :mykey => lambda do |value| ... end
      # (see LogStash::Inputs::File for example)
      result = nil

      if validator.nil?
        return true
      elsif validator.is_a?(Proc)
        return validator.call(value)
      elsif validator.is_a?(Array)
        if value.size > 1
          return false, "Expected one of #{validator.inspect}, got #{value.inspect}"
        end

        if !validator.include?(value.first)
          return false, "Expected one of #{validator.inspect}, got #{value.inspect}"
        end
        result = value.first
      elsif validator.is_a?(Symbol)
        # TODO(sissel): Factor this out into a coersion method?
        # TODO(sissel): Document this stuff.
        value = hash_or_array(value)

        case validator
          when :hash
            if value.is_a?(Hash)
              result = value
            else
              if value.size % 2 == 1
                return false, "This field must contain an even number of items, got #{value.size}"
              end

              # Convert the array the config parser produces into a hash.
              result = {}
              value.each_slice(2) do |key, value|
                entry = result[key]
                if entry.nil?
                  result[key] = value
                else
                  if entry.is_a?(Array)
                    entry << value
                  else
                    result[key] = [entry, value]
                  end
                end
              end
            end
          when :array
            result = value
          when :string
            if value.size > 1 # only one value wanted
              return false, "Expected string, got #{value.inspect}"
            end
            result = value.first
          when :number
            if value.size > 1 # only one value wanted
              return false, "Expected number, got #{value.inspect}"
            end
            if value.first.to_s.to_i.to_s != value.first.to_s
              return false, "Expected number, got #{value.first.inspect}"
            end
            result = value.first.to_i
          when :boolean
            if value.size > 1 # only one value wanted
              return false, "Expected boolean, got #{value.inspect}"
            end

            bool_value = value.first
            if !!bool_value == bool_value
              # is_a does not work for booleans
              # we have Boolean and not a string
              result = bool_value
            else
              if bool_value !~ /^(true|false)$/
                return false, "Expected boolean 'true' or 'false', got #{bool_value.inspect}"
              end

              result = (bool_value == "true")
            end
          when :ipaddr
            if value.size > 1 # only one value wanted
              return false, "Expected IPaddr, got #{value.inspect}"
            end

            octets = value.split(".")
            if octets.length != 4
              return false, "Expected IPaddr, got #{value.inspect}"
            end
            octets.each do |o|
              if o.to_i < 0 or o.to_i > 255
                return false, "Expected IPaddr, got #{value.inspect}"
              end
            end
            result = value.first
          when :password
            if value.size > 1
              return false, "Expected password (one value), got #{value.size} values?"
            end

            result = ::LogStash::Util::Password.new(value.first)
        end # case validator
      else
        return false, "Unknown validator #{validator.class}"
      end

      # Return the validator for later use, like with type coercion.
      return true, result
    end # def validate_value

    def hash_or_array(value)
      if !value.is_a?(Hash)
        value = [*value] # coerce scalar to array if necessary
      end
      return value
    end
  end # module LogStash::Config::DSL
end # module LogStash::Config
