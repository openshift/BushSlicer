lib_path = File.expand_path(File.dirname(File.dirname(__FILE__)))
unless $LOAD_PATH.any? {|p| File.expand_path(p) == lib_path}
  $LOAD_PATH.unshift(lib_path)
end

require 'azure_mgmt_storage'
require 'azure_mgmt_compute'
require 'azure_mgmt_resources'
require 'azure_mgmt_network'

require 'collections'
require 'common'

module BushSlicer
  class Azure
    include Common::Helper
    include CollectionsIncl

    Storage = ::Azure::Storage::Mgmt::V2018_02_01
    Network = ::Azure::Network::Mgmt::V2018_06_01
    # in V2018_06_01 #disks method is missing
    # https://github.com/Azure/azure-sdk-for-ruby/issues/1614
    Compute = ::Azure::Compute::Mgmt::V2018_04_01
    Resource = ::Azure::Resources::Mgmt::V2018_02_01

    StorageModels = Storage::Models
    NetworkModels = Network::Models
    ComputeModels = Compute::Models
    ResourceModels = Resource::Models

    attr_reader :azure_config

    def initialize(**opts)
      @azure_config = conf[:services, opts.delete(:service_name) || :azure]
      @azure_config ||= {}
      @azure_config = deep_merge @azure_config, opts
    end

    def credentials
      @credentials ||= MsRest::TokenCredentials.new(token_provider)
    end

    def token_provider
      return @token_provider if @token_provider
      @token_provider = MsRestAzure::ApplicationTokenProvider.new(
        azure_config[:auth][:tenant_id],
        azure_config[:auth][:client_id],
        azure_config[:auth][:client_secret]
      )
    end

    def default_subscription_id
      azure_config[:subscription_id]
    end

    # @return [ComputeManagementClient] for the provided subscription id
    def compute_client(subs_id = default_subscription_id)
      return @compute_clients[subs_id] if @compute_clients&.dig(subs_id)

      @compute_clients ||= {}
      @compute_clients[subs_id] = Compute::ComputeManagementClient.new(credentials)
      @compute_clients[subs_id].subscription_id = subs_id
      return @compute_clients[subs_id]
    end

    # @return [ResourceManagementClient] for the provided subscription id
    def resource_mgmt_client(subs_id = default_subscription_id)
      return @resource_mgmt_clients[subs_id] if @resource_mgmt_clients&.dig(subs_id)

      @resource_mgmt_clients ||= {}
      @resource_mgmt_clients[subs_id] = Resource::ResourceManagementClient.new(credentials)
      @resource_mgmt_clients[subs_id].subscription_id = subs_id
      return @resource_mgmt_clients[subs_id]
    end

    def net_client(subs_id = default_subscription_id)
      return @net_clients[subs_id] if @net_clients&.dig(subs_id)

      @net_clients ||= {}
      @net_clients[subs_id] = Network::NetworkManagementClient.new(credentials)
      @net_clients[subs_id].subscription_id = subs_id
      return @net_clients[subs_id]
    end

    def storage_client(subs_id = default_subscription_id)
      return @storage_clients[subs_id] if @storage_clients&.dig(subs_id)

      @storage_clients ||= {}
      @storage_clients[subs_id] = Storage::StorageManagementClient.new(credentials)
      @storage_clients[subs_id].subscription_id = subs_id
      return @storage_clients[subs_id]
    end

    def storage_account_keys(resource_group, storage_account_name, subs_id = default_subscription_id)
      storage_client(subs_id).storage_accounts.
        list_keys(resource_group, storage_account_name).keys
    end

    def object_storage_client(resource_group, storage_account_name, subs_id = default_subscription_id)
      key = [resource_group, storage_account_name, subs_id]
      return @object_storage_clients[key] if @object_storage_clients&.dig(key)

      require 'azure/storage'
      @object_storage_clients ||= {}
      return @object_storage_clients[key] = ::Azure::Storage::Client.create(
        storage_account_name: storage_account_name,
        storage_access_key: storage_account_keys(*key).sample.value
      )
    end

    def blob_client(resource_group, storage_account_name, subs_id = default_subscription_id)
      key = [resource_group, storage_account_name, subs_id]
      return object_storage_client(*key).blob_client
    end

    def resource_groups
      @resource_groups ||= resource_mgmt_client.resource_groups.list
    end

    # @return [String, StorageAccount] where the String is the name of the
    #   new account
    # @note MS recommends using separate acconut for each VM:
    #   https://docs.microsoft.com/en-us/azure/virtual-machines/windows/guidance-compute-single-vm
    private def create_storage_account(location, res_group, subs_id = default_subscription_id)
      storage_account_name = "cucushift00#{rand_str(8, :lowercase_num)}"
      logger.info "Creating a storage account with encryption off named '#{storage_account_name}' in resource group '#{res_group}'."
      storage_create_params = StorageModels::StorageAccountCreateParameters.new.tap do |account|
        account.location = location
        account.sku = StorageModels::Sku.new.tap do |sku|
          sku.name = StorageModels::SkuName::StandardLRS
          sku.tier = StorageModels::SkuTier::Standard
        end
        account.kind = StorageModels::Kind::Storage
        account.encryption = StorageModels::Encryption.new.tap do |encrypt|
          encrypt.services = StorageModels::EncryptionServices.new.tap do |services|
            services.blob = StorageModels::EncryptionService.new.tap do |service|
              service.enabled = false
            end
          end
        end
      end

      return storage_account_name, storage_client(subs_id).storage_accounts.create(res_group, storage_account_name, storage_create_params)
    end

    # @return <Array of VirtualMachine>
    def instances
      compute_client.virtual_machines.list_all
    end

    # call instance_view method with ResourceGroup name and instance_name
    def instance_view(vm_obj)
      rg_name = BushSlicer::Azure.resource_group_from_id(vm_obj.id)
      inst_view = compute_client.virtual_machines.instance_view(rg_name, vm_obj.name)
      return rg_name, inst_view
    end

    def instance_view_time(inst_view)
      inst_view.statuses.first.time.strftime
    end

    def vm_disk_creation_time(inst_view)
      inst_view.disks.first.statuses.first.time.strftime
    end
    # use of vm_disk time is more accurate than instance_view (which resets if a user stops and restart the instance)
    def instance_uptime(inst_view, src: "vm_disk")
      time_src = nil
      if src == 'vm_disk'
        time_src = vm_disk_creation_time(inst_view)
      else
        time_src = instance_view_time(inst_view)
      end
      ((Time.now - Time.parse(time_src))/ (60 * 60)).round(2)
    end

    def running? (inst_view)
      # I've seen inst_view.statuses[1] is Nil
      if inst_view.statuses[1].nil?
        return false
      else
        inst_view.statuses[1].code == 'PowerState/running'
      end
    end

    def get_running_instances
      vms = {}
      instances = self.instances
      instances.each do |inst|
        rg_name, iv = instance_view(inst)
        vms[rg_name] = [] if vms[rg_name].nil?
        if running? iv
          uptime = instance_uptime(iv)
          vms[rg_name] << {:inst => inst,
            :inst_view => iv,
            :uptime => uptime }
        end
      end
      # cleanup Hash if the value is an empty array.
      vms.each do |k,v|
        vms.delete k if v.empty?
      end
      return vms
    end

    def get_volume_by_openshift_metadata(pv_name, project_name)
      TODO
      disk_id_regex = ".*\"kubernetes.io/created-for/pv/name\":\"#{pv_name}\".*\"kubernetes.io/created-for/pvc/namespace\":\"#{project_name}\".*"
      ld = compute.list_disks(@config[:project], @config[:zone], filter: "description eq #{disk_id_regex}").items
      if ld
        return ld.first
      else
        return nil
      end
    end

    # @return [TODO, nil] returns nil when not found
    # @raise on communication error
    def get_volume_by_id(id)
      name = id.split("/")[-1]
      res = "volume " + id + " exists"
      begin
      compute_client.disks.get(azure_config[:resource_group], name)
      rescue MsRestAzure::AzureOperationError => e
        if e.response.status == 404
          res = nil
        else
          res = e.response
        end
      end
      return res
    end

    # @param names [String, Array<String>] one or more names to launch
    # @param project [String] project name we work with
    # @param zone [String] zone name we work with
    # @param user_data [String] convenience to add metadata `startup-script` key
    # @param instance_opts [Hash] additional machines launch options
    # @param host_opts [Hash] additional machine access options, should be
    #   options valid for use in [BushSlicer::Host] constructor
    # @param boot_disk_opts [Hash] convenience way to merge some options for
    #   the boot disk without need to replace the whole disks configuration;
    #   disks from global config will be searched for the boot option and that
    #   disk entry will be intelligently merged
    # @param availability_set [String] name of availability set for VM, if value
    #   is :auto, a new one is created based on VM name without trailing numbers
    # @return [Array] of [Instance, BushSlicer::Host] pairs
    def create_instance( names,
                         fqdn_names: azure_config[:fqdn_names],
                         user_data: azure_config[:user_data],
                         os_opts: {},
                         hardware_opts: {},
                         storage_opts: {},
                         network_opts: {},
                         location: azure_config[:location],
                         machine_type: 'Microsoft.Compute/virtualMachines',
                         resource_group: azure_config[:resource_group],
                         availability_set: nil,
                         host_opts: {}
                       )

      names = [ names ].flatten.map {|n| normalize_instance_name(n)}
      vmnames = fqdn_names ? names.map {|n| fqdn_of(n, location)} : names

      ## best effort delete any existing instances with same name
      delete_many_instances(
        vmnames.map { |name| {name: name, resource_group: resource_group} }
      )

      # instance create settings
      availability_set ||= azure_config[:availability_set]
      host_opts = azure_config[:host_connect_opts].merge host_opts
      storage_opts = azure_config[:storage_options].merge storage_opts
      network_opts = azure_config[:network_options].merge network_opts
      hardware_opts = azure_config[:hardware_options].merge hardware_opts
      os_opts = (azure_config[:os_options] || {}).merge os_opts

      ## create the instances
      requests = names.zip(vmnames).map do |name, vmname|
        logger.debug "triggering instance create for #{vmname}"

        params = ComputeModels::VirtualMachine.new
        params.name = name
        params.type = machine_type
        params.os_profile = os_profile(vmname, os_opts)
        params.hardware_profile = hw_profile(hardware_opts)
        params.storage_profile = storage_profile(location, resource_group, name, storage_opts)
        params.network_profile = network_profile(location, resource_group, name, network_opts)
        params.location = location
        params.availability_set = availability_set(resource_group, params, availability_set)

        compute_client.virtual_machines.create_or_update_async(
          resource_group,
          vmname,
          params
        )
      end

      return requests.map.with_index do |create_op, index|
        logger.info "waiting for instance '#{vmnames[index]}'.."
        result = create_op.value!

        instance = result.body
        host_opts ||= {}
        host_opts = host_opts.merge({
          cloud_instance: instance,
          cloud_instance_name: instance.name
        })
        # this can be a hostname or IP depending on instance config
        ip = instance_external_ips(instance).first
        if ip
          logger.info "started #{instance.name}: #{ip}}"
        else
          raise "instance '#{instance.name}' with no public IP allocated"
        end
        host = Host.from_hostname(ip, host_opts)
        if fqdn_names && host.hostname != instance.name
          logger.warn "Azure generated '#{host.hostname}' " \
            "but we expected '#{instance.name}'"
        end
        [instance, host]
      end
    end

    alias create_instances create_instance

    # @return [Object] undefined
    def delete_instance(vmname, resource_group=azure_config[:resource_group])
      if compute_client.virtual_machines.delete(resource_group, vmname)
        logger.info "deleted instance '#{vmname}'"
      else
        logger.info "instance '#{resource_group}/#{vmname}' not found"
      end
    end

    # @return [Object] undefined
    def delete_disk(name, resource_group=azure_config[:resource_group])
      if compute_client.disks.delete(resource_group, name)
        logger.info "deleted disk '#{name}'"
      else
        logger.info "disk '#{resource_group}/#{name}' not found"
      end
    end

    # @param list [Array<Hash>] where Hash is like `{name: "..", resource_group: ".."}`
    #   and `resource_group` is optional
    # @return [Object] undefined
    def delete_many_instances(list)
      del = list.map do |instance|
        name = instance[:name]
        resource_group = instance[:resource_group] || azure_config[:resource_group]
        compute_client.virtual_machines.delete_async(resource_group, name)
      end
      del.each_with_index do |op, index|
        op.wait!
        if op&.value&.body&.status == "Succeeded"
          logger.warn "deleting instance '#{list[index][:name]}'"
        else
          # when instance not found, body is nil, other errors should raise
          #   during `wait!`
        end
      end

      # delete any automatic availability sets without error checking
      del = list.map { |instance|
        resource_group = instance[:resource_group] || azure_config[:resource_group]
        name = "#{resource_group}-#{instance[:name].sub(/[-_]\d*$/, "").sub(/\..+$/, "")}"
        [name, resource_group]
      }.uniq
      del.each do |name, resource_group|
        compute_client.availability_sets.delete_async(resource_group, name)
      end
    end

    # @param [Array<Hash>] launch_opts where each element is in the format
    #   `{name: "some-name", launch_opts: {...}}`; launch opts should match options for
    #   [#create_instance]
    # @return [Object] undefined
    def delete_by_launch_opts(launch_opts)
      delete_many_instances(
        launch_opts.map do |instance_opts|
          {
            name: instance_opts[:name],
            resource_group: instance_opts.dig(:launch_opts, :resource_group)
          }
        end
      )
    end
    alias terminate_by_launch_opts delete_by_launch_opts

    private def fqdn_of(name, location)
      if name.include? "."
        return name
      else
        return "#{name}.#{location}.cloudapp.azure.com"
      end
    end

    # @return [OSProfile] return OS Profile based on supplied options
    private def os_profile(vmname, opts)
      p = ComputeModels::OSProfile.new
      p.computer_name = vmname
      p.admin_username = 'faux'
      p.admin_password = 'ignore this password'

      if opts[:ssh_key]
        ssh_key_path = expand_private_path opts[:ssh_key]
        ssh_key = File.read ssh_key_path
        p.linux_configuration = ComputeModels::LinuxConfiguration.new.tap do |l|
          l.disable_password_authentication = true
          l.ssh = ComputeModels::SshConfiguration.new.tap do |ssh_config|
            ssh_config.public_keys = [
              ComputeModels::SshPublicKey.new.tap do |pub_key|
                pub_key.key_data = ssh_key
                # note: anything but this value appears to be unsupported atm
                # pub_key.path = '/home/root/.ssh/authorized_keys'
                pub_key.path = '/home/faux/.ssh/authorized_keys'
              end
            ]
          end
        end
      end
      return p
    end

    def is_blob_uri?(str)
      BushSlicer::Azure.is_blob_uri? str
    end

    # @return [String, nil] when the string is not a blob URI
    def storage_account_from_blob_uri(str)
      BushSlicer::Azure.send :storage_account_from_blob_uri, str
    end

    # creates or finds an availability set for a given future VM
    private def availability_set(resource_group, vm, name)
      case name
      when nil
        nil
      when :auto, ":auto"
        name = "#{resource_group}-#{vm.name.sub(/[-_]\d*$/, "")}"
        params = ComputeModels::AvailabilitySet.new.tap do |as|
          # as.name = name
          as.location = vm.location
          unless self.class.instance_storage_account(vm)
            # for managed disks "aligned" sku is required,
            # otherwise default "classic"
            # https://docs.microsoft.com/en-us/powershell/module/azurerm.compute/new-azurermavailabilityset?view=azurermps-6.8.1
            as.sku = ComputeModels::Sku.new.tap do |sku|
              sku.name = "aligned"
            end
            as.platform_fault_domain_count = 2
          end
        end
        compute_client.availability_sets.create_or_update(resource_group, name, params)
      else
        raise "selecting existing availability set not supporter yet by " \
          "Flexy installer"
      end
    end

    # @param group [String] resource group
    private def security_group(location, group, name)
      case name
      when nil
        nil
      when :auto, ":auto"
        security_group_name = "cucushift-flexy-vnet-#{location}"
        security_group = net_client.network_security_groups.get_async(group, security_group_name)
        security_group.wait
        raise "timeout getting security group" if security_group.incomplete?
        if security_group.rejected?
          if MsRestAzure::AzureOperationError === security_group.reason && security_group.reason.error_code == "ResourceNotFound"
            sg = NetworkModels::NetworkSecurityGroup.new.tap do |sg|
              sg.location = location
              sg.security_rules = [
                NetworkModels::SecurityRule.new.tap { |sr|
                  sr.name = "AllowInternetInBound"
                  sr.description = "Allow all inbound internet traffic."
                  sr.direction = NetworkModels::SecurityRuleDirection::Inbound
                  sr.source_address_prefix = 'Internet'
                  sr.source_port_range = "*"
                  sr.destination_address_prefix = "*"
                  sr.destination_port_range = "*"
                  sr.protocol = "*"
                  sr.priority = 1000
                  sr.access = NetworkModels::SecurityRuleAccess::Allow
                }
              ]
            end
            net_client.network_security_groups.create_or_update(group, security_group_name, sg)
          else
            raise security_group.reason
          end
        else
          security_group = security_group.value!.body
        end
      when String
        security_group = net_client.network_security_groups.get(group, name)
      else
        raise "selecting existing security group not supporter yet by " \
          "Flexy installer"
      end
    end

    # @return [StorageProfile] return OS Profile based on supplied options
    # @note When storage_options => os_disk => params => image is provided
    #   in config and that is a VHD, then storage account from that URI will
    #   be used.
    #   When Image name or marketplace image props are provided then
    #   storage account from storage_options => :storage_account will be used.
    #   storage_options => :storage_account can be with value :create to crete
    #   a new storage account.
    #   If storage_options => :storage_account is NOT provided, then a managed
    #   disk will be used.
    private def storage_profile(location, resource_group, vmname, opts)
      ComputeModels::StorageProfile.new.tap do |store_profile|
        if is_blob_uri? opts[:os_disk][:params][:image]
          storage_account_name = storage_account_from_blob_uri(
                                               opts[:os_disk][:params][:image])
        elsif opts[:os_disk][:params][:image]
          # we are using a managed image (virtual machine image) instead of a
          #   platform image (VHD in a storage account)
          image = compute_client.images.list_by_resource_group(resource_group).find { |i|
            opts[:os_disk][:params][:image] == i.name
          }
          if image
            store_profile.image_reference = ComputeModels::ImageReference.new.tap do |ref|
              ref.id = image.id
            end
          else
            raise "could not find image: '#{opts[:os_disk][:params][:image]}'"
          end
        else
          store_profile.image_reference = ComputeModels::ImageReference.new.tap do |ref|
            ref.publisher = opts[:os_disk][:params][:publisher]
            ref.offer = opts[:os_disk][:params][:offer]
            ref.sku = opts[:os_disk][:params][:sku]
            ref.version = opts[:os_disk][:params][:version]
          end
        end
        type = BushSlicer::Azure.const_get opts[:os_disk][:type]
        unless type = ComputeModels::DiskCreateOptionTypes::FromImage
          raise "only fromImage is presently supported"
        end

        ## check if user wants a storage account; if :image contained a vhd uri
        #  this would have already been set
        unless storage_account_name
          if opts[:storage_account] == :create
            storage_account_name, storage_account = create_storage_account(location, resource_group)
          elsif opts[:storage_account]
            storage_account_name = opts[:storage_account]
          else
            # storage account nil because we will use managed disk
          end
        end

        container = "cucushift"
        blob_name = "#{vmname}.vhd"

        store_profile.os_disk = ComputeModels::OSDisk.new.tap do |os_disk|
          if is_blob_uri? opts[:os_disk][:params][:image]
            unless opts[:os_disk][:params][:os_type]
              raise "please specify os_disk=>params=>os_type"
            end
            os_disk.image = ComputeModels::VirtualHardDisk.new.tap do |vhd|
              vhd.uri = opts[:os_disk][:params][:image]
            end
            # e.g. Azure::ARM::Compute::Models::OperatingSystemTypes::Linux
            os_disk.os_type = BushSlicer::Azure.const_get opts[:os_disk][:params][:os_type]
          end
          os_disk.name = "#{vmname}"
          if opts.dig(:os_disk, :disk_size_gb)
            os_disk.disk_size_gb = opts.dig(:os_disk, :disk_size_gb)
          end
          os_disk.caching = ComputeModels::CachingTypes::ReadWrite
          os_disk.create_option = type

          if storage_account_name
            os_disk.vhd = ComputeModels::VirtualHardDisk.new.tap do |vhd|
              vhd.uri = "https://#{storage_account_name}.blob.core.windows.net/#{container}/#{blob_name}"
            end
            ## try to delete conflicting VHD
            begin
              blob_client(resource_group, storage_account_name).
                delete_blob(container, blob_name)
            rescue => e
              unless ::Azure::Core::Http::HTTPError === e && e.status_code == 404
                logger.warn "Error removing stale VHD:\n#{exception_to_string(e)}"
              end
            end
          else
            # use managed disk
            os_disk.managed_disk = ComputeModels::ManagedDiskParameters.new.tap do |params|
              params.storage_account_type = StorageModels::SkuName::StandardLRS

              delete_disk(os_disk.name, resource_group)
            end
          end
        end

        return store_profile
      end
    end

    # @return [HardwareProfile] return hardware profile based on options
    private def hw_profile(opts)
      p = ComputeModels::HardwareProfile.new
      p.vm_size = opts[:vm_size]
      return p
    end

    # @param location [String] the location datacenter of network interfaces
    # @param group [String] the name of the resource group
    # @param vmname [string] the name of the VM we are creating interfaces for
    # @param opts [Hash] options for the network profile
    # @return [NetworkProfile] return network profile based on options
    private def network_profile(location, group, vmname, opts)
      # TODO: allow subnet from config
      vnet_name = "cucushift-flexy-vnet-#{location}"
      vnet = net_client.virtual_networks.get_async(group, vnet_name)
      vnet.wait
      raise "timeout getting vnet" if vnet.incomplete?
      if vnet.rejected?
        if MsRestAzure::AzureOperationError === vnet.reason && vnet.reason.error_code == "ResourceNotFound"
          # create a new vnet
          vnet_create_params = NetworkModels::VirtualNetwork.new.tap do |vnet|
            vnet.location = location
            vnet.address_space = NetworkModels::AddressSpace.new.tap do |addr_space|
              addr_space.address_prefixes = ['10.1.2.0/24']
            end
            vnet.dhcp_options = NetworkModels::DhcpOptions.new.tap do |dhcp|
              # dhcp.dns_servers = ['8.8.8.8']
              dhcp.dns_servers = []
            end
            vnet.subnets = [
              NetworkModels::Subnet.new.tap do |subnet|
                subnet.name = 'default-subnet'
                subnet.address_prefix = '10.1.2.0/24'
                subnet.network_security_group = security_group(location, group, opts[:security_group])
              end
            ]
          end
          logger.info "creating a new virtual network '#{vnet_name}'.."
          vnet = net_client.virtual_networks.create_or_update(group, vnet_name, vnet_create_params)
        else
          raise vnet.reason
        end
      else
        vnet = vnet.value!.body
      end


      public_ip_params = NetworkModels::PublicIPAddress.new.tap do |ip|
        ip.location = location
        ip.public_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
        ip.dns_settings = NetworkModels::PublicIPAddressDnsSettings.new.tap do |dns|
          dns.domain_name_label = vmname
        end
      end
      logger.info "creating a new dynamic allocated public" \
                  "ip address '#{vmname}'.."

      # first remove existing ip as update does not work across resource groups
      net_client.network_interfaces.delete(group, "#{vmname}-0")
      net_client.public_ipaddresses.delete(group, vmname)

      public_ip = net_client.public_ipaddresses.create_or_update(group, vmname, public_ip_params)

      logger.info "creating a new network interface '#{vmname}-0'.."
      nic = net_client.network_interfaces.create_or_update(
        group,
        "#{vmname}-0",
        NetworkModels::NetworkInterface.new.tap do |interface|
          interface.location = location
          interface.dns_settings = NetworkModels::NetworkInterfaceDnsSettings.new.tap do |dns|
            dns.internal_dns_name_label = vmname
          end
          interface.ip_configurations = [
            NetworkModels::NetworkInterfaceIPConfiguration.new.tap do |conf|
              conf.name = "#{vmname}-0"
              conf.private_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
              conf.subnet = vnet.subnets[0]
              conf.public_ipaddress = public_ip
              # conf.network_security_group = we set on the subnet level
            end
          ]
        end
      )

      return ComputeModels::NetworkProfile.new.tap do |net_profile|
        net_profile.network_interfaces = [
          ComputeModels::NetworkInterfaceReference.new.tap do |ref|
            ref.id = nic.id
            ref.primary = true
          end
        ]
      end
    end

    # We may need to adjust names, e.g. when longer than 15 characters, see
    # https://docs.microsoft.com/en-us/azure/architecture/best-practices/naming-conventions
    private def normalize_instance_name(name)
      name.gsub("_","-")
    end

    # @param instance [Azure::ARM::Compute::Models::VirtualMachine]
    # @return [Array<String>] FQDNs and/or IPs configured on the VM
    def instance_external_ips(instance)
      ips = []
      interface_references = instance.network_profile.network_interfaces
      interface_references.each do |ref|
        group, int_name = ref.id.scan(%r{resourceGroups/([-\w]+)/providers/Microsoft.Network/networkInterfaces/([-\w]+)})[0]
        interface = net_client.network_interfaces.get(group, int_name)

        interface.ip_configurations.each do |ipc|
          next unless ipc.public_ipaddress&.id

          ip_name = ipc.public_ipaddress.id.scan(%r{resourceGroups/[-\w]+/providers/Microsoft.Network/publicIPAddresses/([-\w]+)})[0]&.at(0)

          ip = net_client.public_ipaddresses.get(group, ip_name)

          if ip.public_ipaddress_version == "IPv4"
            string_ip = ip.dns_settings&.fqdn || ip.ip_address
            ref.primary && ips.unshift(string_ip) || ips.push(string_ip)
          end
        end
      end
      return ips
    end

    # @param instance [Azure::ARM::Compute::Models::VirtualMachine]
    # @return [String] network security group name of VM primary
    #   network interface or subnet
    def instance_security_group(instance)
      nic_ref = instance.network_profile.network_interfaces.find { |nic|
        nic.primary
      }
      m = nic_ref.id.match(%r{/resourceGroups/([^/]+)/.*/([^/]+)$})
      nic = net_client.network_interfaces.get(m[1], m[2])
      security_group = nic.network_security_group
      # https://github.com/Azure/azure-sdk-for-ruby/issues/1616
      return self.class.name_from_id(security_group.id) if security_group

      # expand option might help: https://stackoverflow.com/questions/52121456
      subnet_id = nic.ip_configurations.find {|ipc| ipc.primary}.subnet.id
      m = subnet_id.match(%r{/resourceGroups/([^/]+)/.*/virtualNetworks/([^/]+)/subnets/([^/]+)$})
      subnet = net_client.subnets.get(m[1], m[2], m[3])
      security_group = subnet.network_security_group
      # https://github.com/Azure/azure-sdk-for-ruby/issues/1616
      return self.class.name_from_id(security_group.id) if security_group
    end

    # @param instance [Azure::ARM::Compute::Models::VirtualMachine]
    # @return [String] storage account name used by instance os_disk
    def self.instance_storage_account(instance)
      storage_account_from_blob_uri instance.storage_profile.os_disk.vhd&.uri
    end

    def self.is_blob_uri?(str)
      str&.include? ".blob.core.windows."
    end

    def self.name_from_id(id)
      id.sub(%r{^.+/}, "")
    end

    def self.resource_group_from_id(id)
      id.match(%r{resourceGroups/([^/]+)/})[1]
    end

    # @return [String, nil] when the string is not a blob URI
    private_class_method def self.storage_account_from_blob_uri(str)
      if is_blob_uri? str
        str.gsub(%r{^.*//([\w]+).blob.core.windows.net.*$}, "\\1")
      end
    end
  end
end

## Standalone test
if __FILE__ == $0
  extend BushSlicer::Common::Helper
  azure = BushSlicer::Azure.new
  vms = azure.create_instances(["test-terminate"], fqdn_names: true)

  storage_account = BushSlicer::Azure.instance_storage_account vms[0][0]

  require 'pry'; binding.pry

  # https://github.com/Azure/azure-sdk-for-ruby/issues/1615
  # resource_group = vms[0][0].resource_group
  resource_group = BushSlicer::Azure.resource_group_from_id(vms[0][0].id)
  azure.delete_instance vms[0][0].name

  if storage_account
    puts "Do you want to delete storage account: #{storage_account} (y/N)?"
    do_delete = gets.chomp
    if do_delete == ?y
      logger.info "deleting storage account #{storage_account}.."
      azure.storage_client.storage_accounts.
        delete(resource_group, storage_account)
    end
  end
end
