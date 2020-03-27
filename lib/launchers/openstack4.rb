#!/usr/bin/env ruby

lib_path = File.expand_path(File.dirname(File.dirname(__FILE__)))
unless $LOAD_PATH.any? {|p| File.expand_path(p) == lib_path}
    $LOAD_PATH.unshift(lib_path)
end

require 'json'
require 'io/console' # for reading password without echo
require 'timeout' # to avoid freezes waiting for user input
require 'yaml'

require 'common'
require 'host'
require 'http'
require 'net'

# Will be deleted, obsolete code
module BushSlicer
  # works with OSP4 and OSP7
  # @deprecated Please do not use
  class OpenStack4
    include Common::Helper

    attr_reader :os_tenant_id, :os_tenant_name, :os_service_catalog
    attr_reader :os_user, :os_passwd, :os_url, :opts, :os_volumes_url
    attr_accessor :os_token, :os_image, :os_flavor

    def initialize(**options)
      # by default we look for 'openstack' service in configuration but lets
      #   allow users to keep configuration for multiple OpenStack instances
      service_name = options[:service_name] ||
                     ENV['OPENSTACK_SERVICE_NAME'] ||
                     'openstack_qeos7'
      @opts = default_opts(service_name).merge options

      @proxy = opts[:proxy] || ENV["http_proxy"]

      @os_user = ENV['OPENSTACK_USER'] || opts[:user]
      unless @os_user
        Timeout::timeout(120) do
          STDERR.puts "OpenStack user (timeout in 2 minutes): "
          @os_user = STDIN.gets.chomp
        end
      end
      @os_passwd = ENV['OPENSTACK_PASSWORD'] || opts[:password]
      unless @os_passwd
        STDERR.puts "OpenStack Password: "
        @os_passwd = STDIN.noecho(&:gets).chomp
      end

      @os_tenant_id = options[:tenant_id] || ENV['OPENSTACK_TENANT_ID'] || opts[:tenant_id]
      unless @os_tenant_id
        @os_tenant_name = options[:tenant_name] || ENV['OPENSTACK_TENANT_NAME'] || opts[:tenant_name]
      end

      @os_url = ENV['OPENSTACK_URL'] || opts[:url]

      if ENV['OPENSTACK_IMAGE_NAME'] && !ENV['OPENSTACK_IMAGE_NAME'].empty?
        opts[:image] = ENV['OPENSTACK_IMAGE_NAME']
      elsif ENV['CLOUD_IMAGE_NAME'] && !ENV['CLOUD_IMAGE_NAME'].empty?
        opts[:image] = ENV['CLOUD_IMAGE_NAME']
      end
      raise if opts[:image].nil? || opts[:image].empty?
      opts[:flavor] = ENV.fetch('OPENSTACK_FLAVOR_NAME') { opts[:flavor] }
      opts[:key] = ENV.fetch('OPENSTACK_KEY_NAME') { opts[:key] }

      self.get_token()
    end

    def proxy_set?()
        return @proxy ? true : false
    end

    # @return [ResultHash]
    # @yield [req_result] if block is given, it is yielded with the result as
    #   param
    def rest_run(url, method, params, token = nil, read_timeout = 60, open_timeout = 60)
      headers = {'Content-Type' => 'application/json',
                 'Accept' => 'application/json'}
      headers['X-Auth-Token'] = token if token

      if headers["Content-Type"].include?("json") &&
          ( params.kind_of?(Hash) || params.kind_of?(Array) )
        params = params.to_json
      end

      req_opts = {
        :url => "#{url}",
        :method => method,
        :payload => params,
        :headers => headers,
        :read_timeout => read_timeout,
        :open_timeout => open_timeout
      }

      if proxy_set?
        req_opts.merge!({ :proxy => @proxy })
      end

      res = Http.request(**req_opts)

      if res[:success]
        if res[:headers] && res[:headers]['content-type']
          content_type = res[:headers]['content-type'][0]
          case
          when content_type.include?('json')
            res[:parsed] = JSON.load(res[:response])
          when content_type.include?('yaml')
            res[:parsed] = YAML.load(res[:response])
          end
        end

        yield res if block_given?
      end
      return res
    end


    # Basic token validity check. So we dont generate a new session when we call get_token()
    def token_valid?()
      if monotonic_seconds - @token_verified_at > 900
        params = {:auth => {"tenantName" => self.os_tenant_name, "token" => {"id" => self.os_token}}}

        res = self.rest_run(self.os_url, "POST", params, self.os_token)
        if res[:success] && res[:exitstatus] == 200
          logger.info "token found. Using already existing token."
          @token_verified_at = monotonic_seconds
          return true
        elsif res[:exitstatus] == 404 || res[:exitstatus] == 401
          return false
        else
          raise "#{res[:error]}"
        end
      else
        return true
      end
    end

    def get_token()
      # TODO: get token via token
      #   http://docs.openstack.org/developer/keystone/api_curl_examples.html
      if self.os_token && self.token_valid?
        return @os_token
      else
        auth_opts = {:passwordCredentials => { "username" => self.os_user, "password" => self.os_passwd }}
        if @os_tenant_id
          auth_opts[:tenantId] = self.os_tenant_id
        else
          auth_opts[:tenantName] = self.os_tenant_name
        end
        params = {:auth => auth_opts}
        res = self.rest_run(self.os_url, "POST", params) do |result|
          parsed = result[:parsed] || next
          @os_token = parsed['access']['token']['id']
          if parsed['access']['token']["tenant"]
            @os_tenant_name ||= parsed['access']['token']["tenant"]["name"]
            @os_tenant_id ||= parsed['access']['token']["tenant"]["id"]
            logger.info "logged in to tenant: #{parsed['access']['token']["tenant"].to_json}"
          else
            raise "no tenant found in reply: #{result[:response]}"
          end
          @os_service_catalog = parsed['access']['serviceCatalog']
        end
        unless @os_token
          logger.error res.to_yaml
          raise "Could not obtain proper token"
        end
        @token_verified_at = monotonic_seconds
        return @os_token
      end
    end

    def os_compute_service
      return @os_compute_service if @os_compute_service
      type = nil

      # older APIs may not work well with volume boot disks but we fallback
      # to older if v3 is not found;
      # also note that some broken OS instances return invalid computev3 URL,
      # and we need to filter our any URLs that don't contain tenant_id
      for service in os_service_catalog
        if service['name'].start_with?("nova") &&
            service['type'].start_with?("compute") &&
            service['endpoints'] && !service['endpoints'].empty? &&
            service['endpoints'][0]['publicURL'] &&
            service['endpoints'][0]['publicURL'].include?(os_tenant_id)
          @os_compute_service = service
          type = service['type']
          if service['type'] == "computev3"
            break
          end
        end
      end

      unless @os_compute_service
        raise "could not find compute API Service in service catalog:\n#{os_service_catalog.to_yaml}"
      end
      unless type == "computev3"
        logger.warn "Using compute API type #{type}, while expecting computev3"
      end

      return @os_compute_service
    end

    def os_compute_url
      # select region?
      os_compute_service['endpoints'][0]['publicURL']
    end

    def os_region
      # maybe we don't want to always use same region?
      os_compute_service['endpoints'][0]['region']
    end

    def os_volumes_url
      return @os_volumes_url if @os_volumes_url
      for service in os_service_catalog
        if service['type'] == "volumev2"
          @os_volumes_url = service['endpoints'][0]['publicURL']
          return @os_volumes_url
        end
      end
      raise "could not find volumes API URL in service catalog:\n#{os_service_catalog.to_yaml}"
    end

    # @return object URL or faises and error
    def get_obj_ref(obj_name, obj_type, quiet: false)
      params = {}
      url = self.os_compute_url + '/' + obj_type
      res = self.rest_run(url, "GET", params, self.os_token)
      if res[:success] && res[:parsed]
        for obj in res[:parsed][obj_type]
          if obj['name'] == obj_name
            ref = obj["links"][0]["href"]
            logger.info("ref of #{obj_type} \"#{obj_name}\": #{ref}")
            return ref
          end
        end
        logger.warn "ref of #{obj_type} \"#{obj_name}\" not found" unless quiet
        return nil
      else
        raise "error getting object reference:\n" << res.to_yaml
      end
    end

    def get_image_ref(image_name)
      @os_image = get_obj_ref(image_name, 'images')
    end

    def get_flavor_ref(flavor_name)
      @os_flavor = get_obj_ref(flavor_name, 'flavors')
    end

    # GET URL should result in all contained objects to be of the given status
    def wait_resource_status(url, status, timeout: 300, interval: 10)
      res = nil
      success = wait_for(timeout) {
        res = rest_run(url, :get, nil, os_token)
        if res[:success]
          if res[:parsed].all? {|k, v| v["status"] == status}
            return res[:parsed]
          end
        else
          raise "error obtaining resource:\n" << res.to_yaml
        end
      }

      raise "after timeout status not #{status} but: " + res[:parsed].map {|k, v| "#{k}:#{v["status"]}"}.join(',')
    end

    def self_link(links)
      links.any? do |l|
        if l["rel"] == "self"
          return l["href"]
        end
      end
      raise "no self link found in:\n#{links.to_yaml}"
    end

    def get_volume_by_name(name, return_key: "self_link")
      volume = nil

      url = self.os_volumes_url + '/' + 'volumes'
      res = self.rest_run(url, "GET", nil, self.os_token)
      if res[:success] && res[:parsed] && res[:exitstatus] == 200
        count = res[:parsed]["volumes"].count do |vol|
          volume = vol if vol["name"] == name
        end
        case count
        when 1
          if return_key == "self_link"
            return self_link(volume["links"])
          elsif return_key == "self"
            return volume
          else
            return volume[return_key]
          end
        when 0
          raise "could not find volume #{name}"
        else
          raise "ambiguous volume name, found #{count}"
        end
      else
        raise "error listing volumes:\n" << res.to_yaml
      end
    end

    def get_volume_by_openshift_metadata(pv_name, project_name)

      vol_res = nil
      url = self.os_volumes_url + '/' + 'volumes/detail'
      res = self.rest_run(url, "GET", nil, self.os_token)
      # cant check directly for the volume as openshift does not provide the whole name of the volume
      if res[:success] && res[:parsed] && res[:exitstatus] == 200
        count = 0
        res[:parsed]["volumes"].count do |vol|
          if pv_name == vol["metadata"]["kubernetes.io/created-for/pv/name"] && project_name == vol["metadata"]["kubernetes.io/created-for/pvc/namespace"]
            vol_res = self.rest_run(self_link(vol["links"]), "GET", nil, self.os_token)
            count += 1
          end
        end
        if vol_res.nil?
          return nil
        elsif vol_res[:success] && vol_res[:parsed] && vol_res[:exitstatus] == 200
          logger.info "volume found: #{vol_res[:response]}"
          return vol_res
        elsif count > 1
          raise "ambiguous volume name, found #{count}"
        else
          raise "#{vol_res[:error]}:\n" << vol_res.to_yaml
        end
      else
        raise "#{res[:error]}:\n" << res.to_yaml
      end
    end

    def get_volume_by_id(id)
      url = self.os_volumes_url + '/' + 'volumes' + '/' + id
      res = self.rest_run(url, "GET", nil, self.os_token)
      if res[:exitstatus] == 200
          return res[:parsed]['volume']
      elsif res[:exitstatus] == 404
          return nil
      else
        raise "#{res[:error]}:\n" << res.to_yaml
      end
    end

    def get_volume_state(vol)
      if vol
        return vol['status']
      else
        raise "nil volume given, does your volume exist?"
      end
    end


    def clone_volume(src_name: nil, url: nil, id:nil , name:)
      if [src_name, url, id].count{|o| o} != 1
        raise "specify exactly one of 'src_name', 'url' and 'id'"
      end

      case
      when src_name
        id = get_volume_by_name(src_name, return_key: "id")
      when url
        id = url.gsub(%r{^.*/([^/]+)$}, '\\1')
      end

      payload = %Q^
        {
          "volume": {
            "availability_zone": null,
            "source_volid": "#{id}",
            "description": "BushSlicer created volume",
            "multiattach ": false,
            "snapshot_id": null,
            "name": "#{name}"
          }
        }
      ^

      url = self.os_volumes_url + '/' + 'volumes'
      res = self.rest_run(url, "POST", payload, self.os_token)
      if res[:success] && res[:parsed] && res[:exitstatus] == 202
        logger.info "cloned volume #{id} to #{name}"
        return self_link res[:parsed]["volume"]["links"]
      else
        raise "error cloning volume:\n" << res.to_yaml
      end
    end

    def create_volume_from_image(size:, image:, name:)
      payload = %Q^
        {
          "volume": {
            "size": #{size},
            "availability_zone": null,
            "source_volid": null,
            "description": "BushSlicer created volume",
            "multiattach ": false,
            "snapshot_id": null,
            "name": "#{name}",
            "imageRef": "#{get_image_ref image}",
            "volume_type": null,
            "metadata": {},
            "source_replica": null,
            "consistencygroup_id": null
          }
        }
      ^

      url = self.os_volumes_url + '/' + 'volumes'
      res = self.rest_run(url, "POST", payload, self.os_token)
      if res[:success] && res[:parsed] && res[:exitstatus] == 202
        logger.info "created volume #{name} #{size}GiB from #{image}"
        return self_link res[:parsed]["volume"]["links"]
      else
        raise "error creating volume:\n" << res.to_yaml
      end
    end

    def create_instance_api_call(instance_name, image: nil,
                        flavor_name: nil, key: nil, **create_opts)
      flavor_name ||= create_opts.delete(:flavor) || opts[:flavor]
      key ||= create_opts.delete(:key) || opts[:key]
      image ||= create_opts.delete(:image) || opts[:image]
      networks ||= create_opts.delete(:networks) || opts[:networks]
      new_boot_volume = create_opts.delete(:new_boot_volume) || opts[:new_boot_volume]
      block_device_mapping_v2 = create_opts.delete(:block_device_mapping_v2) || opts[:block_device_mapping_v2]

      self.delete_instance(instance_name)
      self.get_flavor_ref(flavor_name)
      params = {:server => {:name => instance_name, :key_name => key , :flavorRef => self.os_flavor}.merge(create_opts)}
      params[:server][:networks] = networks if networks

      case
      when Array === block_device_mapping_v2 && block_device_mapping_v2.size > 0
        # TODO process mappings to help with image/flavor/volume/snapshot UUIDs
        params[:server][:block_device_mapping_v2] = block_device_mapping_v2
      when new_boot_volume && new_boot_volume > 0
        self.get_image_ref(image) || raise("image #{image} not found")
        params[:server][:block_device_mapping_v2] = [
          {
            boot_index: "0",
            uuid: self.os_image.gsub(%r{.*/},""),
            source_type: "image",
            volume_size: new_boot_volume.to_s,
            destination_type: "volume",
            delete_on_termination: "true"
          },{
          # this may also attach empty ephemeral second disk depending on flavor
            source_type: "blank",
            destination_type: "local",
            # guest_format: "swap"
            guest_format: "ephemeral"
          }
        ]
      else
        # regular boot disk from image
        self.get_image_ref(image) || raise("image #{image} not found")
        params[:server][:imageRef] = self.os_image
      end

      url = self.os_compute_url + '/' + 'servers'
      res = self.rest_run(url, "POST", params, self.os_token)
      if res[:success] && res[:parsed]
        logger.info("created instance: #{instance_name}")
        return res[:parsed]
      else
        logger.error("Can not create #{instance_name}")
        raise "error creating instance:\n" << res.to_yaml
      end
    end

    # doesn't really work if you didn't use tenant when authenticating
    def list_tenants
      url = self.os_compute_url + '/' + 'tenants'
      res = self.rest_run(url, "GET", {}, self.os_token)
      return res[:parsed]
    end

    def create_instance(instance_name, **create_opts)
      params = nil
      server = nil
      url = nil

      attempts = 120
      attempts.times do |attempt|
        logger.info("launch attempt #{attempt}..")

        # if creation attempt was performed, get instance status
        if server
          server.reload
        end

        # on first iteration and on instance launch failure we retry
        if !server || server.status == "ERROR"
          logger.info("** attempting to create an instance..")
          res = create_instance_api_call(instance_name, **create_opts)
          server = Instance.new(spec: res["server"], client: self) rescue next
          sleep 15
        elsif server.status == "ACTIVE"
          if server.floating_ip
            return server
          else
            self.assign_ip(server.name)
          end
        else
          logger.info("Wait 10 seconds to get the IP of #{instance_name}")
          sleep 10
        end
      end
      raise "could not create instance properly after #{attempts} attempts"
    end

    def delete_instance(instance_name)
      params = {}
      url = self.get_obj_ref(instance_name, "servers", quiet: true)
      if url
        logger.warn("deleting old instance \"#{instance_name}\"")
        self.rest_run(url, "DELETE", params, self.os_token)
        1.upto(60)  do
          sleep 10
          if self.get_obj_ref(instance_name, "servers", quiet: true)
            logger.info("Wait for 10s to delete #{instance_name}")
          else
            return true
          end
        end
        raise "could not delete old instance \"#{instance_name}\""
      end
    end

    def assign_ip(instance_name)
      assigning_ip = nil
      params = {}
      url = self.os_compute_url + '/os-floating-ips'
      res = self.rest_run(url, "GET", params, self.os_token)
      result = res[:parsed]
      result['floating_ips'].shuffle.each do | ip |
        if ip['instance_id'] == nil
          assigning_ip = ip['ip']
          logger.info("The floating ip is #{assigning_ip}")
          break
        end
      end

      params = { "addFloatingIp" => {"address" => assigning_ip }}
      instance_href = self.get_obj_ref(instance_name, 'servers') + "/action"
      self.rest_run(instance_href, "POST", params, self.os_token)
    end

    # @param service_name [String] the service name of this openstack instance
    #   to lookup in configuration
    def default_opts(service_name)
      return  conf[:services, service_name.to_sym]
    end

    # launch multiple instances in OpenStack
    # @param os_opts [Hash] options to pass to [OpenStack::new]
    # @param names [Array<String>] array of names to give to new machines
    # @return [Hash] a hash of name => hostname pairs
    # TODO: make this return a [Hash] of name => BushSlicer::Host pairs
    def launch_instances(names:, **create_opts)
      res = {}
      host_opts = create_opts[:host_opts] || {}
      host_opts = opts[:host_opts].merge(host_opts) # merge with global opts
      names.each { |name|
        instance = create_instance(name, **create_opts)
        host_opts[:cloud_instance_name] = instance.name
        host_opts[:cloud_instance] = instance
        res[name] = Host.from_ip(instance.floating_ip, host_opts)
      }
      return res
    end


    class Instance
      attr_reader :client

      # @param client [BushSlicer::OpenStack] the client to use for operations
      # @param name [String] instance name as shown in console; required unless
      #   `spec` is provided
      # @param spec [Hash] the hash describing instance as returned by API
      def initialize(client:, name: nil, spec: nil)
        @spec = spec
        @name = name
        @client = client
      end

      private def spec(refresh: false)
        return @spec if @spec && !refresh

        res = client.rest_run(url, "GET", {}, client.os_token)

        if res[:success]
          @spec = res[:parsed]["server"]
        else
          client.logger.error res[:response]
          raise "could not get instance"
        end

        return @spec
      end

      def reload
        spec(refresh: true)
        nil
      end

      def id
        return @id ||= spec["id"]
      end

      def sec_groups
        return @sec_group ||= spec["security_groups"]
      end

      def url
        return @url if @url

        if @spec
          @url = spec["links"].find {|l| l["rel"] == "self"}["href"]
        else
          @url = client.get_obj_ref(name, "servers", quiet: true)
        end

        return @url
      end

      def region
        # if we ever support multiple regions, we might be smart comparing
        #   instance URL to the client endploints URLs
        client.os_region
      end

      def name(refresh: false)
        if refresh && !@spec
          raise "cannot refresh instance name given we don't have spec"
        elsif !refresh && !@spec
          @name
        else
          reload if refresh
          @spec["name"] || @name || raise("cannot (yet) get instance name, you can try to refresh later")
        end
      end

      ["metadata", "created", "tenant_id", "key_name",
       "updated", "addresses", "status"].each do |prop|
        define_method(prop) do |refresh: false|
          val = spec(refresh: refresh)[prop]
        end
      end

      # @return one floating IP from the selected protocol version
      def floating_ip(refresh: false, proto: 4)
        if addresses(refresh: refresh)
          addresses.first[1].each do |addr|
            if addr["version"] = proto && addr["OS-EXT-IPS:type"] == "floating"
              return addr["addr"]
            end
          end
          return nil
        else
          return nil
        end
      end

      # @return one internal IP from the selected protocol version
      def internal_ip(refresh: false, proto: 4)
        if addresses(refresh: refresh)
          addresses.first[1].each do |addr|
            if addr["version"] = proto && addr["OS-EXT-IPS:type"] == "fixed"
              return addr["addr"]
            end
          end
          return nil
        else
          return nil
        end
      end
    end
  end
end

## Standalone test
if __FILE__ == $0
  extend BushSlicer::Common::Helper
  test_res = {}
  conf[:services].each do |name, service|
    if service[:cloud_type] == 'openstack' && service[:ver] == 7 && service[:password]
      os = BushSlicer::OpenStack4.new(service_name: name)
      res = true
      test_res[name] = res
      begin
        os.launch_instances(names: ["test_terminate"])
        os.delete_instance "test_terminate"
        test_res[name] = false
      rescue => e
        test_res[name] = e
      end
    end
  end

  test_res.each do |name, res|
    puts "OpenStack instance #{name} failed: #{res}"
  end

  require 'pry'
  binding.pry
  #puts test.create_instance("xiama_test", 'RHEL6.5-qcow2-updated-20131213', 'm1.medium')
  #test.delete_instance('test')
end
