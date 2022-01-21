# frozen_string_literal: true

require 'faraday'
require 'faraday_middleware'
require 'json'
require 'net/http'

require_relative 'kubeclient/aws_eks_credentials'
require_relative 'kubeclient/config'
require_relative 'kubeclient/entity_list'
require_relative 'kubeclient/exec_credentials'
require_relative 'kubeclient/gcp_auth_provider'
require_relative 'kubeclient/http_error'
require_relative 'kubeclient/informer'
require_relative 'kubeclient/missing_kind_compatibility'
require_relative 'kubeclient/oidc_auth_provider'
require_relative 'kubeclient/resource'
require_relative 'kubeclient/resource_not_found_error'
require_relative 'kubeclient/resource_already_exists_error'
require_relative 'kubeclient/version'
require_relative 'kubeclient/watch_stream'

module Kubeclient
  # Kubernetes Client
  class Client
    ENTITY_METHODS = %w[get watch delete create update patch json_patch merge_patch apply].freeze

    DEFAULT_SSL_OPTIONS = {
      client_cert: nil,
      client_key:  nil,
      ca_file:     nil,
      cert_store:  nil,
      verify_ssl:  OpenSSL::SSL::VERIFY_PEER
    }.freeze

    DEFAULT_AUTH_OPTIONS = {
      username:          nil,
      password:          nil,
      bearer_token:      nil,
      bearer_token_file: nil
    }.freeze

    DEFAULT_SOCKET_OPTIONS = {
      socket_class:     nil,
      ssl_socket_class: nil
    }.freeze

    DEFAULT_TIMEOUTS = {
      # These do NOT affect watch, watching never times out.
      open: Net::HTTP.new('127.0.0.1').open_timeout, # depends on ruby version
      read: Net::HTTP.new('127.0.0.1').read_timeout
    }.freeze

    DEFAULT_HTTP_PROXY_URI = nil
    DEFAULT_HTTP_MAX_REDIRECTS = 10

    SEARCH_ARGUMENTS = {
      'labelSelector'   => :label_selector,
      'fieldSelector'   => :field_selector,
      'resourceVersion' => :resource_version,
      'limit'           => :limit,
      'continue'        => :continue
    }.freeze

    WATCH_ARGUMENTS = {
      'labelSelector'   => :label_selector,
      'fieldSelector'   => :field_selector,
      'resourceVersion' => :resource_version,
      'allowWatchBookmarks' => :allow_watch_bookmarks
    }.freeze

    attr_reader :api_endpoint
    attr_reader :ssl_options
    attr_reader :auth_options
    attr_reader :http_proxy_uri
    attr_reader :http_max_redirects
    attr_reader :headers
    attr_reader :discovered

    def initialize(
      uri,
      version,
      **options
    )
      unless version.is_a?(String)
        raise ArgumentError, "second argument must be an api version like 'v1'"
      end
      initialize_client(
        uri,
        '/api',
        version,
        **options
      )
    end

    def initialize_client(
      uri,
      path,
      version,
      ssl_options: DEFAULT_SSL_OPTIONS,
      auth_options: DEFAULT_AUTH_OPTIONS,
      socket_options: DEFAULT_SOCKET_OPTIONS,
      timeouts: DEFAULT_TIMEOUTS,
      http_proxy_uri: DEFAULT_HTTP_PROXY_URI,
      http_max_redirects: DEFAULT_HTTP_MAX_REDIRECTS,
      as: :ros
    )
      validate_auth_options(auth_options)
      handle_uri(uri, path)

      @entities = {}
      @discovered = false
      @api_version = version
      @headers = {}
      @ssl_options = ssl_options
      @auth_options = auth_options
      @socket_options = socket_options
      # Allow passing partial timeouts hash, without unspecified
      # @timeouts[:foo] == nil resulting in infinite timeout.
      @timeouts = DEFAULT_TIMEOUTS.merge(timeouts)
      @http_proxy_uri = http_proxy_uri ? http_proxy_uri.to_s : nil
      @http_max_redirects = http_max_redirects
      @as = as

      if (file = auth_options[:bearer_token_file]) # rubocop:disable Style/GuardClause
        validate_bearer_token_file(file)
        @auth_options[:bearer_token] = File.read(file).chomp
      end
    end

    def configure_faraday(&block)
      @faraday_client = create_faraday_client(&block)
    end

    def method_missing(method_sym, *args, &block)
      if discovery_needed?(method_sym)
        discover
        send(method_sym, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(method_sym, include_private = false)
      if discovery_needed?(method_sym)
        discover
        respond_to?(method_sym, include_private)
      else
        super
      end
    end

    def discovery_needed?(method_sym)
      !@discovered && ENTITY_METHODS.any? { |x| method_sym.to_s.start_with?(x) }
    end

    def handle_exception
      yield
    rescue Faraday::Error => e
      err_message = build_http_error_message(e)
      response_code = e.response ? (e.response[:status] || e.response&.env&.status) : nil

      error_klass = if response_code == 404
                      ResourceNotFoundError
                    elsif response_code == 409 && build_http_conflict_reason(e) == 'AlreadyExists'
                      ResourceAlreadyExistsError
                    else
                      HttpError
                    end

      raise error_klass.new(response_code, err_message, e.response)
    end

    def build_http_error_message(e)
      json_error_msg =
        begin
          JSON.parse(e.response[:body] || '') || {}
        rescue StandardError
          {}
        end
      json_error_msg['message'] || e.message || ''
    end

    def discover
      load_entities
      define_entity_methods
      @discovered = true
    end

    def self.parse_definition(kind, name)
      # Kubernetes gives us 3 inputs:
      #   kind: "ComponentStatus", "NetworkPolicy", "Endpoints"
      #   name: "componentstatuses", "networkpolicies", "endpoints"
      #   singularName: "componentstatus" etc (usually omitted, defaults to kind.downcase)
      # and want to derive singular and plural method names, with underscores:
      #   "network_policy"
      #   "network_policies"
      # kind's CamelCase word boundaries determine our placement of underscores.

      if IRREGULAR_NAMES[kind]
        # In a few cases, the given kind / singularName itself is still plural.
        # We require a distinct singular method name, so force it.
        method_names = IRREGULAR_NAMES[kind]
      else
        # TODO: respect singularName from discovery?
        # But how?  If it differs from kind.downcase, kind's word boundaries don't apply.
        singular_name = kind.downcase

        if !(/[A-Z]/ =~ kind)
          # Some custom resources have a fully lowercase kind - can't infer underscores.
          method_names = [singular_name, name]
        else
          # Some plurals are not exact suffixes, e.g. NetworkPolicy -> networkpolicies.
          # So don't expect full last word to match.
          /^(?<prefix>.*[A-Z])(?<singular_suffix>[^A-Z]*)$/ =~ kind # "NetworkP", "olicy"
          if name.start_with?(prefix.downcase)
            plural_suffix = name[prefix.length..-1] # "olicies"
            prefix_underscores = underscore_entity(prefix) # "network_p"
            method_names = [
              prefix_underscores + singular_suffix, # "network_policy"
              prefix_underscores + plural_suffix # "network_policies"
            ]
          else
            method_names = resolve_unconventional_method_names(name, kind, singular_name)
          end
        end
      end

      OpenStruct.new(
        entity_type:   kind,
        resource_name: name,
        method_names:  method_names
      )
    end

    def self.resolve_unconventional_method_names(name, kind, singular_name)
      underscored_name = name.tr('-', '_')
      singular_underscores = underscore_entity(kind)
      if underscored_name.start_with?(singular_underscores)
        [singular_underscores, underscored_name]
      else
        # fallback to lowercase, no separators for both names
        [singular_name, underscored_name.tr('_', '')]
      end
    end

    def handle_uri(uri, path)
      raise ArgumentError, 'Missing uri' unless uri
      @api_endpoint = (uri.is_a?(URI) ? uri : URI.parse(uri))

      # This regex will anchor at the last `/api`, `/oapi` or`/apis/:group`) part of the URL
      # The whole path will be matched and if existing, the api_group will be extracted.
      re = /^(?<path>.*\/o?api(?:s\/(?<apigroup>[^\/]+))?)$/mi
      match = re.match(@api_endpoint.path.chomp('/'))

      if match
        # Since `re` captures 2 groups, match will always have 3 elements
        # If thus we have a non-nil value in match 2, this is our api_group.
        @api_group = match[:apigroup].nil? ? '' : "#{match[:apigroup]}/"
        @api_endpoint.path = match[:path]
      else
        # This is a fallback, for when `/api` was not provided as part of the uri
        @api_group = ''
        @api_endpoint.path = @api_endpoint.path.chomp('/') + path
      end
    end

    def build_namespace_prefix(namespace)
      namespace.to_s.empty? ? '' : "namespaces/#{namespace}/"
    end

    # rubocop:disable  Metrics/BlockLength
    def define_entity_methods
      @entities.each_value do |entity|
        # get all entities of a type e.g. get_nodes, get_pods, etc.
        define_singleton_method("get_#{entity.method_names[1]}") do |options = {}|
          get_entities(entity.entity_type, entity.resource_name, options)
        end

        # watch all entities of a type e.g. watch_nodes, watch_pods, etc.
        define_singleton_method("watch_#{entity.method_names[1]}") do |options = {}, &block|
          # This method used to take resource_version as a param, so
          # this conversion is to keep backwards compatibility
          options = { resource_version: options } unless options.is_a?(Hash)

          watch_entities(entity.resource_name, options, &block)
        end

        # get a single entity of a specific type by name
        define_singleton_method("get_#{entity.method_names[0]}") \
        do |name, namespace = nil, opts = {}|
          get_entity(entity.resource_name, name, namespace, opts)
        end

        define_singleton_method("delete_#{entity.method_names[0]}") \
        do |name, namespace = nil, opts = {}|
          delete_entity(entity.resource_name, name, namespace, **opts)
        end

        define_singleton_method("create_#{entity.method_names[0]}") do |entity_config|
          create_entity(entity.entity_type, entity.resource_name, entity_config)
        end

        define_singleton_method("update_#{entity.method_names[0]}") do |entity_config|
          update_entity(entity.resource_name, entity_config)
        end

        define_singleton_method("patch_#{entity.method_names[0]}") \
        do |name, patch, namespace = nil|
          patch_entity(entity.resource_name, name, patch, 'strategic-merge-patch', namespace)
        end

        define_singleton_method("json_patch_#{entity.method_names[0]}") \
        do |name, patch, namespace = nil|
          patch_entity(entity.resource_name, name, patch, 'json-patch', namespace)
        end

        define_singleton_method("merge_patch_#{entity.method_names[0]}") \
        do |name, patch, namespace = nil|
          patch_entity(entity.resource_name, name, patch, 'merge-patch', namespace)
        end

        define_singleton_method("apply_#{entity.method_names[0]}") do |resource, opts = {}|
          apply_entity(entity.resource_name, resource, **opts)
        end
      end
    end
    # rubocop:enable  Metrics/BlockLength

    # Inspired by https://stackoverflow.com/questions/1509915/converting-camel-case-to-underscore-case-in-ruby
    def self.underscore_entity(entity_name)
      entity_name
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2') # ABCd -> AB_Cd
        .gsub(/([a-z])([A-Z])/, '\1_\2') # AbcD -> Abc_D
        .downcase
    end

    def create_faraday_client(url = nil)
      url = "#{@api_endpoint}/#{@api_version}" if url.nil?
      options = {
        proxy: @http_proxy_uri,
        request: {
          open_timeout: @timeouts[:open],
          read_timeout: @timeouts[:read]
        },
        ssl: {
          ca_file: @ssl_options[:ca_file],
          cert_store: @ssl_options[:cert_store],
          client_cert: @ssl_options[:client_cert],
          client_key: @ssl_options[:client_key],
          verify: @ssl_options[:verify_ssl]
        }
      }

      Faraday.new(url, options) do |connection|
        if @auth_options[:username]
          connection.basic_auth(@auth_options[:username], @auth_options[:password])
        elsif @auth_options[:bearer_token]
          connection.authorization(:Bearer, @auth_options[:bearer_token])
        end

        # hook for adding custom faraday configuration
        yield(connection) if block_given?

        connection.use(FaradayMiddleware::FollowRedirects, limit: @http_max_redirects)
        connection.response(:raise_error)
      end
    end

    def faraday_client
      @faraday_client ||= create_faraday_client
    end

    # Accepts the following options:
    #   :namespace (string) - the namespace of the entity.
    #   :name (string) - the name of the entity to watch.
    #   :label_selector (string) - a selector to restrict the list of returned objects by labels.
    #   :field_selector (string) - a selector to restrict the list of returned objects by fields.
    #   :resource_version (string) - shows changes that occur after passed version of a resource.
    #   :as (:raw|:ros) - defaults to :ros
    #     :raw - return the raw response body as a string
    #     :ros - return a collection of RecursiveOpenStruct objects
    # Accepts an optional block, that will be called with each entity,
    # otherwise returns a WatchStream
    def watch_entities(resource_name, options = {}, &block)
      ns = build_namespace_prefix(options[:namespace])

      path = "watch/#{ns}#{resource_name}"
      path += "/#{options[:name]}" if options[:name]
      uri = @api_endpoint.merge("#{@api_endpoint.path}/#{@api_version}/#{path}")

      params = {}
      WATCH_ARGUMENTS.each { |k, v| params[k] = options[v] if options[v] }
      uri.query = URI.encode_www_form(params) if params.any?

      watcher = Kubeclient::Common::WatchStream.new(
        uri,
        http_options(uri),
        formatter: ->(value) { format_response(options[:as] || @as, value) }
      )

      return_or_yield_to_watcher(watcher, &block)
    end

    # Accepts the following options:
    #   :namespace (string) - the namespace of the entity.
    #   :label_selector (string) - a selector to restrict the list of returned objects by labels.
    #   :field_selector (string) - a selector to restrict the list of returned objects by fields.
    #   :limit (integer) - a maximum number of items to return in each response
    #   :continue (string) - a token used to retrieve the next chunk of entities
    #   :as (:raw|:ros) - defaults to :ros
    #     :raw - return the raw response body as a string
    #     :ros - return a collection of RecursiveOpenStruct objects
    def get_entities(entity_type, resource_name, options = {})
      params = {}
      SEARCH_ARGUMENTS.each { |k, v| params[k] = options[v] if options[v] }

      ns_prefix = build_namespace_prefix(options[:namespace])
      response = handle_exception do
        faraday_client.get(ns_prefix + resource_name, params)
      end
      format_response(options[:as] || @as, response.body, entity_type)
    end

    # Accepts the following options:
    #   :as (:raw|:ros) - defaults to :ros
    #     :raw - return the raw response body as a string
    #     :ros - return a collection of RecursiveOpenStruct objects
    def get_entity(resource_name, name, namespace = nil, options = {})
      ns_prefix = build_namespace_prefix(namespace)
      response = handle_exception do
        faraday_client.get("#{ns_prefix}#{resource_name}/#{name}")
      end
      format_response(options[:as] || @as, response.body)
    end

    # delete_options are passed as a JSON payload in the delete request
    def delete_entity(resource_name, name, namespace = nil, delete_options: {})
      delete_options_hash = delete_options.to_hash
      ns_prefix = build_namespace_prefix(namespace)
      payload = delete_options_hash.to_json unless delete_options_hash.empty?
      response = handle_exception do
        faraday_client.delete(
          "#{ns_prefix}#{resource_name}/#{name}",
          nil,
          json_headers
        ) do |request|
          request.body = payload
        end
      end
      format_response(@as, response.body)
    end

    def create_entity(entity_type, resource_name, entity_config)
      # Duplicate the entity_config to a hash so that when we assign
      # kind and apiVersion, this does not mutate original entity_config obj.
      hash = entity_config.to_hash

      ns_prefix = build_namespace_prefix(hash[:metadata][:namespace])

      # TODO: temporary solution to add "kind" and apiVersion to request
      # until this issue is solved
      # https://github.com/GoogleCloudPlatform/kubernetes/issues/6439
      hash[:kind] = entity_type
      hash[:apiVersion] = @api_group + @api_version
      response = handle_exception do
        faraday_client.post(ns_prefix + resource_name, hash.to_json, json_headers)
      end
      format_response(@as, response.body)
    end

    def update_entity(resource_name, entity_config)
      name      = entity_config[:metadata][:name]
      ns_prefix = build_namespace_prefix(entity_config[:metadata][:namespace])
      params = entity_config.to_h.to_json
      response = handle_exception do
        faraday_client.put("#{ns_prefix}#{resource_name}/#{name}", params, json_headers)
      end
      format_response(@as, response.body)
    end

    def patch_entity(resource_name, name, patch, strategy, namespace)
      ns_prefix = build_namespace_prefix(namespace)
      response = handle_exception do
        faraday_client.patch(
          "#{ns_prefix}#{resource_name}/#{name}",
          patch.to_json,
          { 'Content-Type' => "application/#{strategy}+json" }
        )
      end
      format_response(@as, response.body)
    end

    def apply_entity(resource_name, resource, field_manager:, force: true)
      name = "#{resource[:metadata][:name]}?fieldManager=#{field_manager}&force=#{force}"
      ns_prefix = build_namespace_prefix(resource[:metadata][:namespace])
      response = handle_exception do
        faraday_client.patch(
          "#{ns_prefix}#{resource_name}/#{name}",
          resource.to_json,
          { 'Content-Type' => 'application/apply-patch+yaml' }
        )
      end
      format_response(@as, response.body)
    end

    def all_entities(options = {})
      discover unless @discovered
      @entities.values.each_with_object({}) do |entity, result_hash|
        # method call for get each entities
        # build hash of entity name to array of the entities
        method_name = "get_#{entity.method_names[1]}"
        begin
          result_hash[entity.method_names[0]] = send(method_name, options)
        rescue Kubeclient::HttpError
          next # do not fail due to resources not supporting get
        end
      end
    end

    def get_pod_log(
      pod_name, namespace,
      container: nil, previous: false,
      timestamps: false, since_time: nil, tail_lines: nil, limit_bytes: nil
    )
      params = {}
      params[:previous] = true if previous
      params[:container] = container if container
      params[:timestamps] = timestamps if timestamps
      params[:sinceTime] = format_datetime(since_time) if since_time
      params[:tailLines] = tail_lines if tail_lines
      params[:limitBytes] = limit_bytes if limit_bytes

      ns = build_namespace_prefix(namespace)
      handle_exception do
        faraday_client.get("#{ns}pods/#{pod_name}/log", params).body
      end
    end

    def watch_pod_log(pod_name, namespace, container: nil, &block)
      # Adding the "follow=true" query param tells the Kubernetes API to keep
      # the connection open and stream updates to the log.
      params = { follow: true }
      params[:container] = container if container

      ns = build_namespace_prefix(namespace)

      uri = @api_endpoint.dup
      uri.path += "/#{@api_version}/#{ns}pods/#{pod_name}/log"
      uri.query = URI.encode_www_form(params)

      watcher = Kubeclient::Common::WatchStream.new(
        uri, http_options(uri), formatter: ->(value) { value }
      )
      return_or_yield_to_watcher(watcher, &block)
    end

    def proxy_url(kind, name, port, namespace = '')
      discover unless @discovered
      entity_name_plural =
        if %w[services pods nodes].include?(kind.to_s)
          kind.to_s
        else
          @entities[kind.to_s].resource_name
        end
      ns_prefix = build_namespace_prefix(namespace)
      "#{@api_endpoint}/#{@api_version}/#{ns_prefix}#{entity_name_plural}/#{name}:#{port}/proxy"
    end

    def process_template(template)
      ns_prefix = build_namespace_prefix(template[:metadata][:namespace])
      response = handle_exception do
        faraday_client.post("#{ns_prefix}processedtemplates", template.to_h.to_json, json_headers)
      end
      JSON.parse(response.body)
    end

    def api_valid?
      result = api
      result.is_a?(Hash) && (result['versions'] || []).any? do |group|
        @api_group.empty? ? group.include?(@api_version) : group['version'] == @api_version
      end
    end

    def api
      response = handle_exception do
        create_faraday_client(@api_endpoint.to_s).get(nil).body
      end
      JSON.parse(response)
    end

    private

    IRREGULAR_NAMES = {
      # In a few cases, the given kind itself is still plural.
      # https://github.com/kubernetes/kubernetes/issues/8115
      'Endpoints'                  => %w[endpoint endpoints],
      'SecurityContextConstraints' => %w[security_context_constraint
                                         security_context_constraints]
    }.freeze

    def build_http_conflict_reason(e)
      json_response =
        begin
          JSON.parse(e.response[:body] || '') || {}
        rescue StandardError
          {}
        end
      json_response['reason']
    end

    # Format datetime according to RFC3339
    def format_datetime(value)
      case value
      when DateTime, Time
        value.strftime('%FT%T.%9N%:z')
      when String
        value
      else
        raise ArgumentError, "unsupported type '#{value.class}' of time value '#{value}'"
      end
    end

    def format_response(as, body, list_type = nil)
      case as
      when :raw
        body
      when :parsed
        JSON.parse(body)
      when :parsed_symbolized
        JSON.parse(body, symbolize_names: true)
      when :ros
        result = JSON.parse(body)

        if list_type
          resource_version =
            result.fetch('resourceVersion') do
              result.fetch('metadata', {}).fetch('resourceVersion', nil)
            end

          # If 'limit' was passed save the continue token
          # see https://kubernetes.io/docs/reference/using-api/api-concepts/#retrieving-large-results-sets-in-chunks
          continue = result.fetch('metadata', {}).fetch('continue', nil)

          # result['items'] might be nil due to https://github.com/kubernetes/kubernetes/issues/13096
          collection = result['items'].to_a.map { |item| Kubeclient::Resource.new(item) }

          Kubeclient::Common::EntityList.new(list_type, resource_version, collection, continue)
        else
          Kubeclient::Resource.new(result)
        end
      when Class
        as.new(body)
      else
        raise ArgumentError, "Unsupported format #{as.inspect}"
      end
    end

    def load_entities
      @entities = {}
      fetch_entities['resources'].each do |resource|
        next if resource['name'].include?('/')
        # Not a regular entity, special functionality covered by `process_template`.
        # https://github.com/openshift/origin/issues/21668
        next if resource['kind'] == 'Template' && resource['name'] == 'processedtemplates'
        resource['kind'] ||=
          Kubeclient::Common::MissingKindCompatibility.resource_kind(resource['name'])
        entity = self.class.parse_definition(resource['kind'], resource['name'])
        @entities[entity.method_names[0]] = entity if entity
      end
    end

    def fetch_entities
      JSON.parse(handle_exception { faraday_client.get(nil).body })
    end

    def validate_auth_options(opts)
      # maintain backward compatibility:
      opts[:username] = opts[:user] if opts[:user]

      if %i[bearer_token bearer_token_file username].count { |key| opts[key] } > 1
        raise(
          ArgumentError,
          'Invalid auth options: specify only one of username/password,' \
          ' bearer_token or bearer_token_file'
        )
      elsif %i[username password].count { |key| opts[key] } == 1
        raise ArgumentError, 'Basic auth requires both username & password'
      end
    end

    def validate_bearer_token_file(file)
      raise ArgumentError, "Token file #{file} does not exist" unless File.file?(file)
      raise ArgumentError, "Token file #{file} cannot be read" unless File.readable?(file)
    end

    def return_or_yield_to_watcher(watcher, &block)
      return watcher unless block_given?

      begin
        watcher.each(&block)
      ensure
        watcher.finish
      end
    end

    def http_options(uri)
      options = {
        basic_auth_user: @auth_options[:username],
        basic_auth_password: @auth_options[:password],
        headers: @headers,
        http_proxy_uri: @http_proxy_uri,
        http_max_redirects: http_max_redirects
      }

      if uri.scheme == 'https'
        options[:ssl] = {
          ca_file: @ssl_options[:ca_file],
          cert: @ssl_options[:client_cert],
          cert_store: @ssl_options[:cert_store],
          key: @ssl_options[:client_key],
          # ruby HTTP uses verify_mode instead of verify_ssl
          # http://ruby-doc.org/stdlib-1.9.3/libdoc/openssl/rdoc/OpenSSL/SSL/SSLContext.html
          verify_mode: @ssl_options[:verify_ssl]
        }
      end

      options.merge(@socket_options)
    end

    def json_headers
      { 'Content-Type' => 'application/json' }
    end
  end
end
