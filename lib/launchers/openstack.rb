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
require 'cucuhttp'
require 'net'
require 'thread'

module BushSlicer
  # works with OSP10 and OSP7
  class OpenStack
    include Common::Helper

    attr_reader :os_domain, :os_tenant_id, :os_tenant_name, :os_service_catalog
    attr_reader :os_user, :os_passwd, :os_url, :opts
    attr_accessor :os_token, :os_image, :os_flavor

    def initialize(**options)
      # by default we look for 'openstack' service in configuration but lets
      #   allow users to keep configuration for multiple OpenStack instances
      service_name = options[:service_name] ||
                     ENV['OPENSTACK_SERVICE_NAME'] ||
                     'openstack_upshift'
      @opts = default_opts(service_name).merge options

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

      #domain needed for v3 auth
      case
      when options[:domain]
        @os_domain = options[:domain]
      when opts[:domain]
        @os_domain = opts[:domain]
      when ENV['OPENSTACK_DOMAIN_ID']
        @os_domain = {id: ENV['OPENSTACK_DOMAIN_ID']}
      when ENV['OPENSTACK_DOMAIN_NAME']
        @os_domain = {name: ENV['OPENSTACK_DOMAIN_NAME']}
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

    # @return [ResultHash]
    # @yield [req_result] if block is given, it is yielded with the result as
    #   param
    def rest_run(url, method, params, token = nil, read_timeout = 60, open_timeout = 60)
      headers = {'Content-Type' => 'application/json',
                 'Accept' => 'application/json'}
      headers['X-Auth-Token'] = token if token

      req_opts = {
        :url => "#{url}",
        :method => method,
        :headers => headers,
        :read_timeout => read_timeout,
        :open_timeout => open_timeout
      }

      if opts.has_key? :proxy
        req_opts[:proxy] = opts[:proxy]
      end

      case method
      when "GET", "DELETE"
        req_opts[:params] = params
      else
        if headers["Content-Type"].include?("json") &&
            ( params.kind_of?(Hash) || params.kind_of?(Array) )
          params = params.to_json
        end
        req_opts[:payload] = params
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
      return @token_expires_at - monotonic_seconds > 60
    end

    def get_token()
      # TODO: get token via token
      #   http://docs.openstack.org/developer/keystone/api_curl_examples.html
      #   https://docs.openstack.org/keystone/latest/api_curl_examples.html
      if self.os_token && self.token_valid?
        return @os_token
      else
        res = self.os_url.include?("/v3/") ? auth_payload_v3 : auth_payload_v2
        unless @os_token
          logger.error res.to_yaml
          raise "Could not obtain proper token"
        end
        return @os_token
      end
    end

    def auth_payload_v2
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
        # try to account for time skew when setting token expiry time
        expires = Time.parse(parsed.dig("access","token", "expires"))
        issued = Time.parse(parsed.dig("access","token", "issued_at"))
        @token_expires_at = monotonic_seconds + (expires - issued)
      end
    end

    def auth_payload_v3
      if @os_tenant_id
        project = { id: self.os_tenant_id }
      else
        project = { name: self.os_tenant_name, domain: self.os_domain }
      end
      auth_opts = {
        auth: {
          identity: {
            methods: ["password"],
            password: {
              user: {
                name: self.os_user,
                password: self.os_passwd,
                domain: self.os_domain
              }
            }
          },
          scope: {project: project}
        }
      }

      res = self.rest_run(self.os_url, "POST", auth_opts) do |result|
        parsed = result[:parsed] || next
        @os_token = result.dig(:headers, "x-subject-token", 0);
        if parsed.dig("token", "project")
          @os_tenant_name ||= parsed.dig("token", "project", "name")
          @os_tenant_id ||= parsed.dig("token", "project", "id")
          logger.info "logged in to tenant: #{parsed.dig("token", "project").to_json}"
        else
          raise "no project found in reply: #{result[:response]}"
        end
        @os_service_catalog = parsed.dig("token", "catalog")
        # try to account for time skew when setting token expiry time
        expires = Time.parse(parsed.dig("token", "expires_at"))
        issued = Time.parse(parsed.dig("token", "issued_at"))
        @token_expires_at = monotonic_seconds + (expires - issued)
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
            service['endpoints'] && !service['endpoints'].empty?
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

      return @os_compute_service
    end

    def os_compute_url
      # select region?
      os_compute_service['endpoints'][0]['publicURL'] ||
        os_compute_service['endpoints'][0]['url']
    end

    def os_region
      # maybe we don't want to always use same region?
      os_compute_service['endpoints'][0]['region']
    end

    def os_volumes_url
      return @os_volumes_url if @os_volumes_url
      for service in os_service_catalog
        if service['type'] == "volumev2"
          for item in service['endpoints']
            if item['interface'] == 'public'
              @os_volumes_url = item['url']
              return @os_volumes_url
            end
          end
        end
      end
      raise "could not find volumes API URL in service catalog:\n#{os_service_catalog.to_yaml}"
    end

    def os_network_service
      return @os_network_service if @os_network_service
      for service in os_service_catalog
        if service['type'] == "network" && service['name'] == "neutron"
          @os_network_service = service
          return @os_network_service
        end
      end
      raise "could not find neutron network API URL in service catalog:\n#{os_service_catalog.to_yaml}"
    end

    def os_network_url
      # select region?
      os_network_service['endpoints'][0]['publicURL'] ||
        os_network_service['endpoints'].
        find{|e| e["interface"] == "public"}['url']
    end

    def get_objects(obj_type, params: nil, quiet: false)
      params ||= {}
      url = self.os_compute_url + '/' + obj_type
      res = self.rest_run(url, "GET", params, self.os_token)
      if res[:success] && res[:parsed]
        return res[:parsed][obj_type]
      else
        "error getting objects:\n" << res.to_json
      end
    end

    def get_object(obj_name, obj_type, quiet: false)
      get_objects(obj_type, quiet: quiet).find { |object|
        object['name'] == obj_name
      }
    end

    # @return object URL or raises an error
    def get_obj_ref(obj_name, obj_type, quiet: false)
      ref = get_object(obj_name, obj_type, quiet: quiet)&.dig("links",0, "href")
      logger.info("ref of #{obj_type} \"#{obj_name}\": #{ref}") if ref
      return ref
    end

    # @return object UUID or raises an error
    def uuid(obj_name, obj_type, quiet: false)
      id = get_object(obj_name, obj_type, quiet: quiet)&.dig("id")
      logger.info("UUID of #{obj_type} \"#{obj_name}\": #{id.inspect}") if id
      return id
    end

    def get_image_ref(image_name)
      @os_image = uuid(image_name, 'images')
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
            "imageRef": "#{uuid image}",
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
      security_groups = create_opts.delete(:security_groups) || opts[:security_groups]
      new_boot_volume = create_opts.delete(:new_boot_volume) || opts[:new_boot_volume]
      block_device_mapping_v2 = create_opts.delete(:block_device_mapping_v2) || opts[:block_device_mapping_v2]

      self.delete_instance(instance_name)
      self.get_flavor_ref(flavor_name)
      params = {:server => {:name => instance_name, :key_name => key , :flavorRef => self.os_flavor}.merge(create_opts)}
      params[:server][:networks] = networks if networks
      params[:server][:security_groups] = security_groups if security_groups

      case
      when Array === block_device_mapping_v2 && block_device_mapping_v2.size > 0
        params[:server][:block_device_mapping_v2] = block_device_mapping_v2.map { |disk|
          disk = Collections.deep_hash_symkeys(disk)
          if disk[:image_name]
            # if image_name is present, convert it to UUID
            image_name = disk.delete(:image_name)
            disk[:uuid] = get_image_ref(image_name)
            raise("image #{image_name} not found") unless disk[:uuid]
          elsif !disk[:uuid] &&
                disk[:boot_index] == 0 &&
                disk[:source_type] == "image"
            # for boot disk without uuid/image_name specified, use the
            # global image option like with simple storage config
            disk[:uuid] = get_image_ref(image)
            raise("image #{image} not found") unless disk[:uuid]
          end
          disk
        }
      when new_boot_volume && new_boot_volume > 0
        uuid = get_image_ref(image) || raise("image #{image} not found")
        params[:server][:block_device_mapping_v2] = [
          {
            boot_index: 0,
            uuid: uuid,
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
        params[:server][:imageRef] = get_image_ref(image) ||
          raise("image #{image} not found")
      end

      ## for image->local combination we also need imageRef, see
      #    https://docs.openstack.org/nova/latest/user/block-device-mapping.html
      boot_disk = params[:server][:block_device_mapping_v2]&.find { |disk|
        disk[:boot_index] == 0
      }
      if boot_disk &&
          boot_disk[:source_type] == "image" &&
          boot_disk[:destination_type] == "local"
        params[:server][:imageRef] = boot_disk[:uuid]
      end

      url = self.os_compute_url + '/' + 'servers'
      logger.debug "creating instance with params:\n#{params.to_yaml}"
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
      ip_assigned = false
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
        elsif server.status == "ACTIVE" &&
                ( !floating_ip_network_id || server.floating_ip )
          return server
        elsif server.status == "ACTIVE" && !ip_assigned
          ip_assigned = assign_ip(server)[:success]
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

    def delete_floating_ip(floating_ip_id)
      url = self.os_network_url + "/v2.0/floatingips/#{floating_ip_id}"
      params = {}
      fip_res = self.rest_run(url, "GET", params, self.os_token)
      if fip_res[:exitstatus] == 404
        logger.warn("the floating ip \"#{floating_ip_id}\" is already deleted")
        return true
      elsif fip_res[:success]
        logger.warn("deleteing floating ip \"#{floating_ip_id}\"")
        res = self.rest_run(url, "DELETE", params, self.os_token)
        unless res[:success]
          raise "failed to delete floating ip \'#{floating_ip_id}\""
        end
        1.upto(60) do
          sleep 10
          res = self.rest_run(url, "GET", params, self.os_token)
          if res[:exitstatus] == 404
            return true
          else
            logger.info("Wait for 10s to delete floating ip #{floating_ip_id}")
          end
        end
        raise "could not delete floating ip #{floating_ip_id}"
      else
        raise "we got some problem to fetch floating ip\n#{fip_res[:response]}"
      end
    end

    # @param [Array<Hash>] launch_opts where each element is in the format
    #   `{name: "some-name", launch_opts: {...}}`; launch opts should match options for
    #   [#create_instance]
    # @return [Object] undefined
    def delete_by_launch_opts(launch_opts)
      launch_opts.each do |instance_opts|
        delete_instance instance_opts[:name]
      end
    end
    alias terminate_by_launch_opts delete_by_launch_opts

    def assign_ip(instance)
      assigning_ip = nil
      params = {}
      url = self.os_network_url + '/v2.0/floatingips'
      res = self.rest_run(url, "GET", params, self.os_token)
      result = res[:parsed]
      result['floatingips'].shuffle.each do | ip |
        if ip['port_id'] == nil &&
            self.os_tenant_id == ip["tenant_id"] &&
            ip['floating_network_id'] == floating_ip_network_id
          assigning_ip = ip
          logger.info("Selecting existing floating ip: #{assigning_ip["floating_ip_address"]}")
          break
        end
      end

      port_id = instance.internal_network_port["id"]
      params = {
        floatingip: {
          fixed_ip_address: instance.internal_ip,
          port_id: port_id
        }
      }

      if assigning_ip
        path = "/" + assigning_ip["id"]
        method = "PUT"
      else
        # allocate a new floating ip and assogn to instance
        path = ""
        method = "POST"
        params[:floatingip].merge!({
          project_id: self.os_tenant_id,
          floating_network_id: floating_ip_network_id,
          description: "IP allocated automatically by BushSlicer"
        })
      end

      res = self.rest_run(self.os_network_url + "/v2.0/floatingips" + path,
                          method,
                          params,
                          self.os_token)
      if res[:success]
        return res
      else
        raise "could not associate a floating ip:\n#{res[:response]}"
      end
    end

    def get_floating_ips()
      res = self.rest_run(self.os_network_url + "/v2.0/floatingips", "GET", {}, self.os_token)
      if res[:success]
        return res.dig(:parsed, "floatingips")
      else
        raise "Could not get all existing floating ips\n#{res[:response]}"
      end
    end

    def allocate_floating_ip(network_name, reuse: true, designator: nil)
      network = floating_ip_networks.find { |n| n["name"] == network_name }
      unless network
        raise "could not find network #{network_name} in current tenant."
      end

      if reuse
        fips = get_floating_ips()
        # filter condition is
        # 1, floating ip is not belong to given network_name and
        # 2, floating ip is not preserved
        # 3, floating ip is not associated to instance
        filtered_fips = fips.find_all { |n|
          n["floating_network_id"] == network["id"] && !n["description"][/[Pp]reserve/] && !n["fixed_ip_address"]
        }
        unless filtered_fips.empty?
          return filtered_fips.sample
        end
      end

      # create new floating ip
      # 1. when reuse is false or
      # 2. no existed floating ip
      request_url = self.os_network_url + "/v2.0/floatingips"
      method = "POST"

      network_id = network["id"]
      payload = {
        floatingip: {
          floating_network_id: network_id,
          project_id: self.os_tenant_id,
          description: "IP allocated automatically by OpenShift verification-tests" \
            + ((designator.nil? || designator.length == 0) ? "":" (#{designator})")
        }
      }
      res = self.rest_run(request_url, method, payload, self.os_token)
      logger.debug(res[:response])
      if res[:success]
        return res.dig(:parsed, "floatingip")
      else
        raise "could not allocate new floating ip:\n#{res[:response]}"
      end
    end

    def assign_ip_to_port(floatingip_id, port_id)
      request_url = self.os_network_url + "/v2.0/floatingips/#{floatingip_id}"
      method = "PUT"
      payload = {
        floatingip: {
          port_id: port_id
        }
      }
      res = self.rest_run(request_url, method, payload, self.os_token)
      logger.debug(res[:response])
      if res[:success]
        return res.dig(:parsed, "floatingip")
      else
        raise "failed to set properties for floating ip:\n#{res[:response]}"
      end
    end

    def create_network(network_name)
      payload = {
        network: {
          name: network_name
        }
      }
      res = self.rest_run(self.os_network_url + "/v2.0/networks", "POST", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]["network"]
    end

    # for example, update the name:
    # update_network("<network_id>", name; "xxx")
    def update_network(network_id, **kargs)
      payload = {
        network: kargs
      }
      res = self.rest_run(self.os_network_url + "/v2.0/networks/" + network_id, "PUT", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res
    end

    def delete_network(network_id)
      res = self.rest_run(self.os_network_url + "/v2.0/networks/" + network_id, "DELETE", {}, self.os_token)
      raise res[:response] unless res[:success]
      return res
    end

    def create_subnet(network_id, cidr)
      payload = {
        subnet: {
          cidr: cidr,
          ip_version: 4,
          network_id: network_id
        }
      }
      res = self.rest_run(self.os_network_url + "/v2.0/subnets", "POST", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]["subnet"]
    end

    # for example, update the name:
    # update_subnet("<network_id>", name: "xxx")
    def update_subnet(subnet_id, **kargs)
      payload = {
        subnet: kargs
      }
      res = self.rest_run(self.os_network_url + "/v2.0/subnets/" + subnet_id, "PUT", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res
    end

    def delete_subnet(subnet_id)
      res = self.rest_run(self.os_network_url + "/v2.0/subnets/" + subnet_id, "DELETE", {}, self.os_token)
      raise res[:response] unless res[:success]
      return res
    end

    # external_gateway_info have three fields
    # {
    #   network_id: "xxx",
    #   "enable_snat": true,
    #   external_fixed_ips: [
    #     {
    #       ip_address: "xxx",
    #       subnet_id: "xxx"
    #     }
    #   ]
    # }
    def create_router(router_name, external_gateway_info)
      payload = {
        router: {
          name: router_name,
          external_gateway_info: external_gateway_info
        }
      }
      res = self.rest_run(self.os_network_url + "/v2.0/routers", "POST", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]["router"]
    end

    def delete_router(router_id)
      res = self.rest_run(self.os_network_url + "/v2.0/routers/" + router_id, "DELETE", {}, self.os_token)
      raise res[:response] unless res[:success]
      return res
    end

    def link_subnet_to_router(router_id, subnet_id)
      payload = {
        subnet_id: subnet_id
      }
      res = self.rest_run(self.os_network_url + "/v2.0/routers/" + router_id + "/add_router_interface", "PUT", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]
    end

    def unlink_subnet_from_router(router_id, subnet_id)
      payload = {
        subnet_id: subnet_id
      }
      res = self.rest_run(self.os_network_url + "/v2.0/routers/" + router_id + "/remove_router_interface", "PUT", payload, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]
    end

    def get_networks
      res = self.rest_run(self.os_network_url + "/v2.0/networks", "GET", {}, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]["networks"]
    end

    def floating_ip_networks(refresh: false)
      return @floating_ip_networks if @floating_ip_networks && !refresh
      return get_networks.select{|n| n["router:external"]}
    end

    # Figure out a working floating ip pool based on the internal network id
    def floating_ip_network_id(refresh: false)
      if opts[:floating_ip_network]
        return opts[:floating_ip_network]
      elsif opts[:floating_ip_network].nil?
        # TODO: automatic detection
        # * find router in network (maybe using default route in subnet)
        # * get router ports
        # * find port of external network
        # * use that network for floating IPs
        # * cache the result
        return floating_ip_networks(refresh: refresh)[0]["id"]
      else # floating_ip_network is false
        return nil
      end
    end

    def network_by_id(id)
      get_networks.find { |n| n["id"] == id }
    end

    def get_routers
      res = self.rest_run(self.os_network_url + "/v2.0/routers", "GET", {}, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]["routers"]
    end

    def get_instances
      get_objects("servers")
    end

    def get_instance_detail(id)
      res = self.rest_run(self.os_compute_url + "/servers/#{id}", "GET", {}, self.os_token)
      raise res[:response] unless res[:success]
      return res[:parsed]
    end

    def get_running_instances
      threads = []
      running_inst = {}
      instances = get_objects("servers")
      instances.each do |instance|
        threads << Thread.new(instance) do | i|
          begin
            inst_details = get_instance_detail(i['id'])
            running_inst[inst_details.dig('server', 'name')] = inst_details['server'] if inst_details.dig('server','status') == "ACTIVE"
          rescue
            next
          end
        end
      end
      threads.each(&:join)
      return running_inst
    end

    # input: timestamp in string format
    def instance_uptime(inst_creation_time)
      ((Time.now.utc - Time.parse(inst_creation_time)) / (60 * 60)).round(2)
    end
    # @return ports of device, e.g. router ports
    def get_ports(device_id: nil, fixed_ips: nil)
      get_opts = {}
      if device_id
        get_opts["device_id"] = device_id
      end
      if fixed_ips
        get_opts["fixed_ips"] = fixed_ips
      end
      res = self.rest_run(self.os_network_url + "/v2.0/ports", "GET", get_opts, self.os_token)

      raise res[:response] unless res[:success]
      return res[:parsed]["ports"]
    end

    # @param service_name [String] the service name of this openstack instance
    #   to lookup in configuration
    def default_opts(service_name)
      return  conf[:services, service_name.to_sym]
    end

    # launch multiple instances in OpenStack
    # @param os_opts [Hash] options to pass to [OpenStack::new]
    # @param host_opts [Hash<Symbol, Object>] options for connecting the host
    # @param names [Array<String>] array of names to give to new machines
    # @return [Hash] a hash of name => hostname pairs
    # TODO: make this return a [Hash] of name => BushSlicer::Host pairs
    def launch_instances(names:, **create_opts)
      res = {}
      host_opts = create_opts.delete(:host_opts) || {}
      host_opts = opts[:host_opts].merge(host_opts) # merge with global opts
      names.each { |name|
        instance = create_instance(name, **create_opts)
        host_opts[:cloud_instance_name] = instance.name
        host_opts[:cloud_instance] = instance
        if instance.floating_ip
          res[name] = Host.from_ip(instance.floating_ip, host_opts)
        else
          res[name] = Host.from_ip(instance.internal_ip, host_opts)
        end
        logger.debug(
          "Host #{res[name][:cloud_instance_name]} has ip #{res[name].ip}."
        )
        res[name].local_ip = instance.internal_ip
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

      def internal_network_port(refresh: false, proto: 4)
        return @internal_network_port if @internal_network_port

        myip = internal_ip(refresh: refresh, proto: proto)
        ports = client.get_ports(fixed_ips: "ip_address=#{myip}")
        port = ports.find {|p| p["fixed_ips"]&.any?{|ip| ip["ip_address"] == myip}}
        if port
          @internal_network_port = port
          return port.freeze
        else
          raise "cannot find port for #{internal_ip}"
        end
      end
    end
  end
end

## Standalone test
if __FILE__ == $0
  extend BushSlicer::Common::Helper
  require 'pry'
  test_res = {}
  service_matcher = ARGV.first || ""
  conf[:services].each do |name, service|
    if service[:cloud_type] == 'openstack' &&
        name.to_s.include?(service_matcher) &&
        service[:password]
      os = BushSlicer::OpenStack.new(service_name: name)
      res = true
      test_res[name] = res
      begin
        res = os.launch_instances(names: ["test_terminate"])
        binding.pry if ARGV[1] == "true"
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

  binding.pry
end
