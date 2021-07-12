require 'rbvmomi'

lib_path = File.expand_path(File.dirname(File.dirname(__FILE__)))
unless $LOAD_PATH.any? {|p| File.expand_path(p) == lib_path}
  $LOAD_PATH.unshift(lib_path)
end

require 'collections'
require 'common'

module BushSlicer
  class VSphere
    include Common::Helper
    include CollectionsIncl
    attr_reader :config

    def initialize(**opts)
      service_name = opts.delete(:service_name)
      if service_name
        @config = conf[:services, service_name]
      else
        @config = {}
      end

      config_opts = opts.delete(:config)
      if config_opts
        deep_merge!(@config, config_opts)
      end
    end

    # @param names [String, Array<String>] one or more names to launch
    # @param user_data [String] not implemented yet
    # @param instance_opts [Hash] additional machines launch options
    # @param host_opts [Hash] additional machine access options, should be
    #   options valid for use in [BushSlicer::Host] constructor
    # @return [Array] of [RbVmomi::VIM::VirtualMachine, BushSlicer::Host] pairs
    def create_instance( names,
                         user_data: nil,
                         create_opts: {},
                         host_opts: {})

      names = [ names ].flatten.map {|n| normalize_instance_name(n)}
      create_opts = deep_merge(config[:create_opts] || {}, create_opts)

      ## create the instances
      case create_opts[:type]
      when :clone
        create = clone_instance(names, **create_opts[:clone_opts])
      else
        raise "create VM type #{create_opts[:type]} not supported"
      end

      vms = create.map.with_index do |create_op, index|
        logger.info "waiting for instance #{names[index]}"
        vm = create_op.wait_for_completion
        instrument_object! vm
        vm
      end

      return vms.map.with_index do |vm, index|
        host_opts = host_opts.merge({cloud_instance_name: names[index]})
        return_val = [vm, get_vm_host(vm, host_opts)]
        logger.info "started #{return_val[0].name}: #{return_val[1].hostname}"
        return_val
      end
    end

    alias create_instances create_instance

    # @param name [String, Array] the new VM/Template name
    # @param from_vm [String, RbVmomi::VIM::VirtualMachine] VM/template to clone
    # @param target_resource_pool [String, RbVmomi::VIM::ResourcePool] or nil to
    #   use the first one we find
    # @param folder [RbVmomi::VIM::Folder, String] folder to create new VM in,
    #   will use the folder of source VM when nil
    # @param edit [Hash] VM edit options after clone, this is not implemented
    # @param power_on [Boolean] whether to power on machine after clone
    # @param template [Boolean] whether to create a template instead of a VM
    # @return [RbVmomi::VIM::Task]
    private def clone_instance(names,
                               from_vm:,
                               from_folder: nil,
                               target_resource_pool: nil,
                               folder: nil,
                               edit: nil,
                               power_on: true,
                               template: false)
      names = [names].flatten

      if edit && !edit.empty?
        # idea is, when edit is provided, to:
        # * clone machine
        # * apply edit trough some mechanism
        # * launch machine (if power_on is set)
        raise "edit machine when cloning is not supported, contact maintainer"
      end

      if String === from_vm
        from_vm_name = from_vm
      end
      from_vm = normalize_vm(from_vm, folder: from_folder)
      from_vm_name ||= from_vm.name
      folder = folder ? normalize_vm_folder(folder) : from_vm.parent
      target_resource_pool = normalize_pool(target_resource_pool)

      # delete existing machines with same name
      destroy_multi(names: names, folder: folder)

      location = RbVmomi::VIM.VirtualMachineRelocateSpec
      location.pool = target_resource_pool
      spec = RbVmomi::VIM.VirtualMachineCloneSpec(
        location: location,
        powerOn: power_on,
        template: template
      )

      # https://code.vmware.com/apis/196/vsphere#/doc/vim.VirtualMachine.html#clone
      clone_opts = {
        folder: folder,
        spec: spec
      }

      return names.map do |name|
        logger.info "cloning #{from_vm_name} into #{name}"
        from_vm.CloneVM_Task(**clone_opts, name: name)
      end
    end

    # @param from_vm [String, RbVmomi::VIM::VirtualMachine] we want to refer to
    # @return [RbVmomi::VIM::VirtualMachine]
    # @raise [ArgumentError] on invalid vm spec
    private def normalize_vm(vm, folder: nil)
      case vm
      when RbVmomi::VIM::VirtualMachine
        vm
      when String
        normalize_vm_folder(folder).find(vm, RbVmomi::VIM::VirtualMachine) ||
          raise(ResourceNotFound, "no vm #{vm} found in folder #{folder}")
      else
        raise ArgumentError, "unknown vm specification #{vm.inspect}"
      end
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @param name [String, RbVmomi::VIM::ResourcePool], returns firs host pool
    #   when nil
    # @return [RbVmomi::VIM::ResourcePool]
    # @raise [ArgumentError] on invalid pool spec
    private def normalize_pool(pool)
      case pool
      when RbVmomi::VIM::ResourcePool
        pool
      when String
        RbVmomi::VIM::ResourcePool.new(connection, pool)
      else
        raise ArgumentError, "unknown pool specification #{pool.inspect}"
      end
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @param folder [RbVmomi::VIM::Folder, String] folder specification
    # @return [RbVmomi::VIM::Folder]
    # @raise [ArgumentError] on invalid folder spec
    private def normalize_vm_folder(folder)
      case folder
      when nil
        datacenter_vm_folder
      when RbVmomi::VIM::Folder
        folder
      when String
        RbVmomi::VIM::Folder.new(connection, folder)
      else
        raise ArgumentError, "unknown folder specified #{folder.inspect}"
      end
    end

    private def normalize_instance_name(name)
      if String === name && !name.empty?
        name # in case we need to normalize the name at some point
      else
        raise ArgumentError, "instance name should be a non-empty string"
      end
    end

    # @param vm [VirtualMachine]
    def wait_guest_ip(vm, vmname: nil, timeout: 300)
      vmname ||= vm.name
      logger.debug "waiting up to #{timeout} seconds for VM #{vmname} " \
        "to get an IP assigned"
      wait_for(timeout, interval: 3) {
        ip = vm.guest_ip
        return ip if ip
      }

      raise BushSlicer::TimeoutError, "VM #{vmname} did not get an IP within " \
        "#{timeout} seconds"
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @param vm [RbVmomi::VIM::VirtualMachine] vm object
    # @return [BushSlicer::Host]
    def get_vm_host(vm, host_opts = {})
      host_opts = (config[:host_connect_opts] || {}).merge host_opts
      host_opts[:cloud_instance] = vm
      host_opts[:cloud_instance_name] ||= vm.name
      ip = wait_guest_ip(vm, vmname: host_opts[:cloud_instance_name])
      return Host.from_ip(ip, host_opts)
      # return Host.from_hostname(ip, host_opts)
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @param [Array<Hash>] launch_opts where each element is in the format
    #   `{name: "some-name", launch_opts: {...}}`;
    #   launch opts should match options for [#create_instance]
    # @return [Object] undefined
    def terminate_by_launch_opts(launch_opts)
      to_del = []

      # group by `launch_opts` so that we handle all names with same
      #   launch_opts together
      groups = launch_opts.group_by {|h| h[:launch_opts]}.values.map do |arr|
        { names: arr.map{|h| h[:name]}, launch_opts: arr.first[:launch_opts] }
      end

      groups.each do |instance_opts|
        names = instance_opts[:names]
        create_opts = deep_merge(
          config.fetch(:create_opts, {}),
          instance_opts[:launch_opts]
        )

        case create_opts[:type]
        when :clone
          folder = create_opts.dig(:clone_opts, :folder)
          if folder
            search_folder = normalize_vm_folder(folder)
          else
            from_folder = create_opts.dig(:clone_opts, :from_folder)
            from_vm = create_opts.dig(:clone_opts, :from_vm)
            from_vm = normalize_vm(from_vm, folder: from_folder)
            search_folder = from_vm.parent
          end
          destroy_multi(names: names, folder: search_folder)
        else
          raise "create VM type #{create_opts[:type]} not supported"
        end
      end
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # convenience delete vms by string name and filder
    # @param name [String] VM name
    # @param folder [RbVmomi::VIM::Folder]
    # @return undefined
    # @raise on errors
    private def destroy_multi(names:, folder:)
      to_del = []
      shutdowns = []
      del = []
      logger.debug "Trying to destroy VSphere instances: #{names}"
      names.each do |name|
        begin
          to_del << normalize_vm(name, folder: folder)
          shutdowns << to_del.last.PowerOffVM_Task
        rescue ResourceNotFound => e
          # no such VM existed so we are good to go
          to_del << nil
          shutdowns << nil
        end
      end

      shutdowns.each_with_index do |op, index|
        if op
          logger.info "Waiting for VSphere instance '#{names[index]}' to " \
            "Power Off"
          # we ignore error on shutdown as it could be shut off already
          op.wait_for_completion rescue nil
          del << to_del[index].Destroy_Task
        else
          del << nil
        end
      end

      del.each_with_index do |op, index|
        if op
          logger.info "waiting destroy operation for #{names[index]}"
          op.wait_for_completion
        end
      end
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @return [RbVmomi::VIM::Folder]
    private def datacenter_vm_folder
      @vm_folder ||= datacenter.vmFolder
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @return [RbVmomi::VIM::Datacenter]
    private def datacenter
      @datacenter ||= connection.serviceInstance.
        find_datacenter(config.dig(:common, :datacenter)) ||
        raise(ResourceNotFound, 'datacenter not found')
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        reconnect
        retry
      else
        raise e
      end
    end

    # @return [RbVmomi::VIM]
    private def connection
      @connection ||= RbVmomi::VIM.connect(**config[:connect])
    end

    private def reconnect
      connection.serviceContent.sessionManager.Login(
        **hash_slice(config[:connect], [:user, :password])
      )
    end

    private def connected?
      connection.instanceUuid
      return true
    rescue RbVmomi::Fault => e
      if e.message.start_with? "NotAuthenticated:"
        return false
      else
        raise
      end
    end

    # when connection session expires, the objects we may pass like
    #   [RbVmomi::VIM::VirtualMachine] would become useless, thus we
    #   can instrument a reconnect method here so these objects can be
    #   made again usable
    # @param object [Object] expected a RbVmomi::VIM::* object that will have
    #   a reconnect method monkey patched
    # @return [Object] the instrumented object
    private def instrument_object!(object)
      object.instance_variable_set(:@connwrapper, self)
      def object.reconect
        connwrapper.reconnect unless conwrapper.connected?
      end
      def object.conwrapper
        @connwrapper
      end
    end

    # @return [Array] of [RbVmomi::VIM::VirtualMachine]
    private def vms(folder: nil)
      folder ||= datacenter.vmFolder
      machines = []
      folder.childEntity.each do |x|
        name, junk = x.to_s.split('(', 2)
        case name
        when "Folder"
          machines.concat vms(folder: x)
        when "VirtualMachine"
          machines << x if x.runtime.powerState == "poweredOn"
          # puts "#{x.name}   => #{x.config.createDate}"
        else
          puts "# Unrecognized Entity " + x.to_s
        end
      end
      return machines
    end

    def get_running_instances
      return vms.select { |i| i.runtime.powerState == "poweredOn" }
    end

    def instance_uptime(timestamp)
      ((Time.now  - timestamp) /(60 * 60)).round(2)
    end

    class VSphereError < StandardError
    end

    class ResourceNotFound < VSphereError
    end
  end
end

## Standalone test
if __FILE__ == $0
  extend BushSlicer::Common::Helper
  test_res = {}
  conf[:services].each do |name, service|
    if service[:cloud_type] == 'vsphere' && service.dig(:connect, :password)
      vim = BushSlicer::VSphere.new(service_name: name)
      res = true
      test_res[name] = res
      begin
        vm, host = vim.create_instance(["test_terminate"]).flatten
        vim.send(:destroy_multi, names: ["test_terminate"], folder: vm.parent)
        test_res[name] = false
      rescue => e
        test_res[name] = e
      end
    end
  end

  test_res.each do |name, res|
    puts "VSphere instance #{name} failed: #{res}"
  end

  require 'pry'; binding.pry
end
