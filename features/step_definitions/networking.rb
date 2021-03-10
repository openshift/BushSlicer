
Given /^I run the ovs commands on the host:$/ do | table |
  ensure_admin_tagged
  _host = node.host
  ovs_cmd = table.raw.flatten.join
  # check if the service is enabled and not if it is active, because it might be failed
  if BushSlicer::Platform::SystemdService.enabled?("openvswitch.service", _host)
    logger.info("environment using systemd to launch openvswitch")
  else
    # For >=3.10 and runc env, should get containerID from the pod which landed on the node
    logger.info("OCP version >= 3.10 and environment may using runc to launch openvswith")
    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    container_id = ovs_pod.containers.first.id
    ovs_cmd = "runc exec #{container_id} " + ovs_cmd
  end
  @result = _host.exec_admin(ovs_cmd)
end

Given /^I run ovs dump flows commands on the host$/ do
  step %Q/I run the ovs commands on the host:/, table(%{
    | ovs-ofctl dump-flows br0 -O openflow13 |
  })
end

Given /^the env is using multitenant network$/ do
  step 'the env is using one of the listed network plugins:', table([["multitenant"]])
end

Given /^the env is using networkpolicy plugin$/ do
  step 'the env is using one of the listed network plugins:', table([["networkpolicy"]])
end

Given /^the env is using multitenant or networkpolicy network$/ do
  step 'the env is using one of the listed network plugins:', table([["multitenant","networkpolicy"]])
end

Given /^the env is using one of the listed network plugins:$/ do |table|
  ensure_admin_tagged
  plugin_list = table.raw.flatten
  _admin = admin

  @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: '{{.pluginName}}')
  if @result[:success]
    # only check stdout because stderr can contain "-" and cause the split to fail
    plugin_name = @result[:stdout].to_s.split("-").last
    unless plugin_list.include? plugin_name
      raise "the env network plugin is #{plugin_name} but expecting #{plugin_list}."
    end
  else
    _host = node.host rescue nil
    unless _host
      step "I store the schedulable nodes in the clipboard"
      _host = node.host
    end

    step %Q/I run the ovs commands on the host:/, table([[
      "ovs-ofctl dump-flows br0 -O openflow13 | grep table=253"
    ]])
    unless @result[:success]
      raise "failed to get table 253 from the open flows."
    end

    plugin_type = @result[:response][-17]
    case plugin_type
    when "0"
      plugin_name = "subnet"
    when "1"
      plugin_name = "multitenant"
    when "2"
      plugin_name = "networkpolicy"
    else
      raise "unknown network plugins."
    end
    logger.info("environment network plugin name: #{plugin_name}")

    unless plugin_list.include? plugin_name
      raise "the env network plugin is #{plugin_name} but expecting #{plugin_list}."
    end
  end
end

Given /^the network plugin is switched on the#{OPT_QUOTED} node$/ do |node_name|
  ensure_admin_tagged

  node_config = node(node_name).service.config
  config_hash = node_config.as_hash
  if config_hash["networkConfig"]["networkPluginName"].include?("subnet")
    config_hash["networkConfig"]["networkPluginName"] = "redhat/openshift-ovs-multitenant"
    logger.info "Switch plguin to multitenant from subnet"
  else
    config_hash["networkConfig"]["networkPluginName"] = "redhat/openshift-ovs-subnet"
    logger.info "Switch plguin to subnet from multitenant/networkpolicy"
  end
  step "node config is merged with the following hash:", config_hash.to_yaml
end

Given /^the#{OPT_QUOTED} node network is verified$/ do |node_name|
  ensure_admin_tagged

  _node = node(node_name)
  _host = _node.host

  net_verify = proc {
    # to simplify the process, ping all node's tun0 IP including the node itself, even test env has only one node
    hostsubnet = BushSlicer::HostSubnet.list(user: admin)
    hostsubnet.each do |hs|
      dest_ip = IPAddr.new(hs.subnet).succ
      @result = _host.exec("ping -c 2 -W 2 #{dest_ip}")
      raise "failed to ping tun0 IP: #{dest_ip}" unless @result[:success]
    end
  }

  net_verify.call
  teardown_add net_verify
end


Given /^the subnet from the clusternetwork resource is stored in the clipboard$/ do
  ensure_admin_tagged
  _admin = admin
  @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default", template: '{{index .clusterNetworks 0 "CIDR"}}')
  unless @result[:success]
    raise "Can not get clusternetwork resource!"
  end
  cb.clusternetwork = @result[:response].chomp
  logger.info "Cluster network #{cb.clusternetwork} saved into the :clusternetwork clipboard"
end


Given /^the#{OPT_QUOTED} node iptables config is checked$/ do |node_name|
  ensure_admin_tagged
  _node = node(node_name)
  _host = _node.host
  _admin = admin

  step "the subnet from the clusternetwork resource is stored in the clipboard"
  subnet = cb.clusternetwork

  plugin_type = ""
  @result = _admin.cli_exec(:get, resource: "clusternetwork", resource_name: "default")
  if @result[:success]
    plugin_type = @result[:response]
  end

  unless plugin_type.include?("openshift-ovs-networkpolicy")
    raise "#{plugin_type} != openshift-ovs-networkpolicy.  This is unsupported?"
  end

  puts "OpenShift version >= 3.9 and uses networkpolicy plugin."
  filter_matches = [
    'INPUT -m comment --comment "Ensure that non-local NodePort traffic can flow" -j KUBE-NODEPORT-NON-LOCAL',
    'INPUT -m conntrack --ctstate NEW -m comment --comment "kubernetes externally-visible service portals" -j KUBE-EXTERNAL-SERVICES',
    'INPUT -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-ALLOW',
    'FORWARD -m comment --comment "firewall overrides" -j OPENSHIFT-FIREWALL-FORWARD',
    'FORWARD -i tun0 ! -o tun0 -m comment --comment "administrator overrides" -j OPENSHIFT-ADMIN-OUTPUT-RULES',
    'OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT',
    'OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT',
    'OPENSHIFT-FIREWALL-ALLOW -i docker0 -m comment --comment "from docker to localhost" -j ACCEPT',
    "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"attempted resend after connection close\" -m conntrack --ctstate INVALID -j DROP",
    "OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT",
    "OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT"
  ]
  nat_matches = [
    "PREROUTING -m comment --comment \".*\" -j KUBE-SERVICES",
    "OUTPUT -m comment --comment \"kubernetes service portals\" -j KUBE-SERVICES",
    "POSTROUTING -m comment --comment \"rules for masquerading OpenShift traffic\" -j OPENSHIFT-MASQUERADE",
    "OPENSHIFT-MASQUERADE -s #{subnet} -m comment --comment \"masquerade .* traffic\" -j OPENSHIFT-MASQUERADE-2",
    "OPENSHIFT-MASQUERADE-2 -d #{subnet} -m comment --comment \"masquerade pod-to-external traffic\" -j RETURN",
    "OPENSHIFT-MASQUERADE-2 -j MASQUERADE"
  ]

  # use a lambda so we can exit early
  iptables_verify = -> {
    @result = _host.exec_admin("iptables-save -t filter")
    filter_matches.each { |match|
      unless @result[:success] && @result[:response] =~ /#{match}/
        @result[:success] = false
        @result[:message] = "The filter table verification failed, missing [#{match}]"
        return
      end
    }

    @result = _host.exec_admin("iptables-save -t nat")
    nat_matches.each { |match|
      unless @result[:success] && @result[:response] =~ /#{match}/
        @result[:success] = false
        @result[:message] = "The nat table verification failed, missing [#{match}]"
        return
      end
    }
  }

  iptables_verify.call

end

Given /^the#{OPT_QUOTED} node standard iptables rules are removed$/ do |node_name|
  ensure_admin_tagged
  _node = node(node_name)
  _host = _node.host
  _admin = admin

  step "the subnet from the clusternetwork resource is stored in the clipboard"
  subnet = cb.clusternetwork

  @result = _host.exec('iptables -D OPENSHIFT-FIREWALL-ALLOW -p udp -m udp --dport 4789 -m comment --comment "VXLAN incoming" -j ACCEPT')
  raise "failed to delete iptables rule #1" unless @result[:success]
  @result = _host.exec('iptables -D OPENSHIFT-FIREWALL-ALLOW -i tun0 -m comment --comment "from SDN to localhost" -j ACCEPT')
  raise "failed to delete iptables rule #2" unless @result[:success]
  @result = _host.exec("iptables -D OPENSHIFT-FIREWALL-FORWARD -d #{subnet} -m comment --comment \"forward traffic from SDN\" -j ACCEPT")
  raise "failed to delete iptables rule #3" unless @result[:success]
  @result = _host.exec("iptables -D OPENSHIFT-FIREWALL-FORWARD -s #{subnet} -m comment --comment \"forward traffic to SDN\" -j ACCEPT")
  raise "failed to delete iptables rule #4" unless @result[:success]

  # compatible with different network plugin
  # limit the match to the main OPENSHIFT-MASQUERADE rule
  @result = _host.exec("iptables -S -t nat \| grep -e 'OPENSHIFT-MASQUERADE -s #{subnet}' \| cut -d ' ' -f 2-")
  raise "failed to grep rule from the iptables nat table!" unless @result[:success]
  # don't use :response because for oc debug :response includes STDERR appended
  nat_rule = @result[:stdout].to_s

  @result = _host.exec("iptables -t nat -D #{nat_rule}")
  raise "failed to delete iptables nat rule" unless @result[:success]
end

Given /^the#{OPT_QUOTED} node standard iptables rules are completely flushed$/ do |node_name|
  ensure_admin_tagged
  _node = node(node_name)
  _host = _node.host
  _admin = admin

  tables = %w(filter mangle nat raw security)

  # try to batch all the changes to make it atomic to try to prevent network issues with debug node
  flush_chain = tables.map { |table|
    "iptables -t #{table} -F"
  }.join(" ; ")
  # Flush all the chains first, then delete to prevent reference issues
  # There must be no references to the chain.
  # If there are, you must delete or replace the referring rules before the chain can be deleted.
  # The chain must be empty, i.e. not contain any rules.
  delete_chain = tables.map { |table|
    "iptables -t #{table} -X"
  }.join(" ; ")
  @result = _host.exec(flush_chain + " ; " + delete_chain)
  # ignore any chain delete errors for now and just see if it triggers the iptableSync, e.g.
  # iptables v1.8.4 (nf_tables):  CHAIN_USER_DEL failed (Device or resource busy): chain KUBE-MARK-MASQ
  raise "failed to flush iptables chains" unless @result[:success]
end

Given /^admin adds( and overwrites)? following annotations to the "(.+?)" netnamespace:$/ do |overwrite, netnamespace, table|
  ensure_admin_tagged
  _admin = admin
  _netnamespace = netns(netnamespace, env)
  _annotations = _netnamespace.annotations

  table.raw.flatten.each { |annotation|
    if overwrite
      @result = _admin.cli_exec(:annotate, resource: "netnamespace", resourcename: netnamespace, keyval: annotation, overwrite: true)
    else
      @result = _admin.cli_exec(:annotate, resource: "netnamespace", resourcename: netnamespace, keyval: annotation)
    end
    raise "The annotation '#{annotation}' was not successfully added to the netnamespace '#{netnamespace}'!" unless @result[:success]
  }

  teardown_add {
    current_annotations = _netnamespace.annotations(cached: false)

    unless current_annotations == _annotations
      current_annotations.keys.each do |annotation|
        @result = _admin.cli_exec(:annotate, resource: "netnamespaces", resourcename: netnamespace, keyval: "#{annotation}-")
        raise "The annotation '#{annotation}' was not removed from the netnamespace '#{netnamespace}'!" unless @result[:success]
      end

      if _annotations
        _annotations.each do |annotation, value|
          @result = _admin.cli_exec(:annotate, resource: "netnamespaces", resourcename: netnamespace, keyval: "#{annotation}=#{value}")
          raise "The annotation '#{annotation}' was not successfully added to the netnamespace '#{netnamespace}'!" unless @result[:success]
        end
      end
      # verify if the restoration process was succesfull
      current_annotations = _netnamespace.annotations(cached: false)
      unless current_annotations == _annotations
        raise "The restoration of netnamespace '#{netnamespace}' was not successfull!"
      end
    end
  }
end

Given /^the DefaultDeny policy is applied to the "(.+?)" namespace$/ do | project_name |
  ensure_admin_tagged

  if env.version_lt("3.6", user: user)
    @result = admin.cli_exec(:annotate, resource: "namespace", resourcename: project_name , keyval: 'net.beta.kubernetes.io/network-policy={"ingress":{"isolation":"DefaultDeny"}}')
    unless @result[:success]
      raise "Failed to apply the default deny annotation to specified namespace."
    end
  else
    @result = admin.cli_exec(:create, n: project_name , f: "#{BushSlicer::HOME}/testdata/networking/networkpolicy/defaultdeny-v1-semantic.yaml")
    unless @result[:success]
      raise "Failed to apply the default deny policy to specified namespace."
    end
  end
end

Given /^the AllowNamespaceAndPod policy is applied to the "(.+?)" namespace$/ do | project_name |
  ensure_admin_tagged

  step %Q{I obtain test data file "networking/networkpolicy/allow-ns-and-pod.yaml"}
  step %Q/I run the :create admin command with:/,table(%{
    | f | allow-ns-and-pod.yaml |
    | n | #{project_name}       |
  })
  step %Q{the step should succeed}
end

Given /^the cluster network plugin type and version and stored in the clipboard$/ do
  ensure_admin_tagged
  _host = node.host

  # TODO: this should be run OVS command
  step %Q/I run command on the node's sdn pod:/, table([["ovs-ofctl"],["dump-flows"],["br0"],["-O"],["openflow13"]])
  unless @result[:success]
    raise "Unable to execute ovs command successfully. Check your command."
  end
  of_note = @result[:response].partition('note:').last.chomp
  cb.net_plugin = {
    type: of_note[0,2],
    version: of_note[3,2]
  }
end

Given /^I wait for the networking components of the node to be terminated$/ do
  ensure_admin_tagged
  _host = node.host
  _admin = admin

  # This step is used when deleteing a node to make sure the Pods are deleted
  # A deleted node does not affect the host OVS state, so we don't do anything with host OVS

  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OpenShiftSDN"
    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    net_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: _admin) { |pod, hash|
      pod.node_name == node.name
    }.first
  when "OVNKubernetes"
    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    net_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
  else
    raise "unknown network_type"
  end

  unless ovs_pod.nil?
    # for host OVS deleteing the OVS pods has no effect.
    @result = ovs_pod.wait_till_not_ready(user, 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "ovs pod on the node did not die"
    end
  end

  unless net_pod.nil?
    @result = net_pod.wait_till_not_ready(user, 3 * 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "#{net_pod.name} pod on the node did not die"
    end
  end

end

Given /^I wait for the networking components of the node to become ready$/ do
  ensure_admin_tagged
  _admin = admin

  _host = node.host
  if BushSlicer::Platform::SystemdService.enabled?("openvswitch.service", _host)
    logger.info("environment using systemd to launch openvswitch")
    BushSlicer::Platform::SystemdService.new("openvswitch.service", _host).start
    BushSlicer::Platform::SystemdService.new("ovsdb-server.service", _host).status[:success]
  else

    ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    @result = ovs_pod.wait_till_ready(_admin, 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "ovs pod on the node did not become ready"
    end
  end

  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OpenShiftSDN"

    sdn_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first

    @result = sdn_pod.wait_till_ready(_admin, 3 * 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "sdn pod on the node did not become ready"
    end
    cache_resources sdn_pod
    cb.sdn_pod = sdn_pod
  when "OVNKubernetes"
    ovnkube_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    cache_resources ovnkube_pod
    @result = ovnkube_pod.wait_till_ready(_admin, 3 * 60)
    unless @result[:success]
      logger.error(@result[:response])
      raise "ovnkube pod on the node did not become ready"
    end
    cache_resources ovnkube_pod
    cb.ovnkube_pod = ovnkube_pod
  else
    raise "unknown network_type"
  end

end

Given /^I restart the openvswitch service on the node$/ do
  ensure_admin_tagged
  _host = node.host
  _admin = admin

  if BushSlicer::Platform::SystemdService.new("openvswitch.service", _host).enabled?
    logger.info("environment using systemd to launch openvswitch")
    # restarting openvswitch will restart the dependent services ovsdb-server and ovs-vswitchd
    BushSlicer::Platform::SystemdService.new("openvswitch.service", _host).restart
  else
    network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
    network_type = network_operator.network_type(user: admin)
    case network_type
    when "OpenShiftSDN"
      ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
        pod.node_name == node.name
      }.first
    when "OVNKubernetes"
      ovs_pod = BushSlicer::Pod.get_labeled("app=ovs-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
        pod.node_name == node.name
      }.first
    else
      raise "unknown network_type"
    end
    @result = ovs_pod.ensure_deleted(user: _admin)
  end

  unless @result[:success]
    raise "Fail to restart the openvswitch service"
  end
end

Given /^I restart the network components on the node( after scenario)?$/ do |after|
  ensure_admin_tagged
  _admin = admin
  _node = node

  restart_network = proc {
      network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
      network_type = network_operator.network_type(user: _admin)
      case network_type
      when "OpenShiftSDN"
        net_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: _admin) { |pod, hash|
          pod.node_name == _node.name
        }.first
      when "OVNKubernetes"
        net_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
          pod.node_name == _node.name
        }.first
      else
        raise "unknown network_type"
      end
      @result = net_pod.ensure_deleted(user: _admin)
  }

  if after
    logger.info "Network components will be restarted after scenario on the node"
    teardown_add restart_network
  else
    restart_network.call
  end
end

Given /^I get the networking components logs of the node since "(.+)" ago$/ do | duration |
  ensure_admin_tagged
  _admin = admin

  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OpenShiftSDN"
    sdn_pod = cb.sdn_pod || BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node.name
    }.first
    @result = admin.cli_exec(:logs, resource_name: sdn_pod.name, n: "openshift-sdn", c: "sdn", since: duration)
  when "OVNKubernetes"
    ovnkube_pod = cb.ovnkube_pod || BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
      pod.node_name == node_name
    }.first
    @result = admin.cli_exec(:logs, resource_name: ovnkube_pod.name, n: "openshift-ovn-kubernetes", since: duration)
  else
    raise "unknown network_type"
  end
end

Given /^the node's default gateway is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  step "I select a random node's host"
  cb_name = "gateway" unless cb_name
  @result = host.exec_admin("ip route show default | awk '/default/ {print $3}'")

  cb[cb_name] = @result[:response].chomp
  unless IPAddr.new(cb[cb_name])
    raise "Failed to get the default gateway"
  end
  logger.info "The node's default gateway is stored in the #{cb_name} clipboard."
end


Given /^I store a random unused IP address from the reserved range to the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  cb_name = "valid_ip" unless cb_name
  step "the subnet for primary interface on node is stored in the clipboard"

  reserved_range = cb.subnet_range

  unused_ips=[]
  #Save four unused ip in the clipboard
  # use the sdn pod instead of the ovs pod since we have switched to host OVS
  IPAddr.new(reserved_range).to_range.to_a.shuffle.each { |ip|
    @result = step "I run command on the node's sdn pod:", table(
      "| ping | -c4 | -W2 | #{ip} |"
    )
    if @result[:exitstatus] == 0
      logger.info "The IP is in use."
    elsif unused_ips.length < 4
      unused_ips << ip.to_s
      logger.info "Get the unused IP #{ip.to_s}"
    else
      break
    end
  }
  cb.valid_ips=unused_ips
  cb[cb_name]=cb.valid_ips[0]
  raise "No available ip found in the range." unless IPAddr.new(cb[cb_name])
end

Given /^the valid egress IP is added to the#{OPT_QUOTED} node$/ do |node_name|
  ensure_admin_tagged
  step "I store a random unused IP address from the reserved range to the clipboard"
  node_name = node.name unless node_name

  @result = admin.cli_exec(:patch, resource: "hostsubnet", resource_name: "#{node_name}", p: "{\"egressIPs\":[\"#{cb.valid_ip}\"]}", type: "merge")
  raise "Failed to patch hostsubnet!" unless @result[:success]
  logger.info "The free IP #{cb.valid_ip} added to egress node #{node_name}."

  teardown_add {
    @result = admin.cli_exec(:patch, resource: "hostsubnet", resource_name: "#{node_name}", p: "{\"egressIPs\":[]}", type: "merge")
    raise "Failed to clear egress IP on node #{node_name}" unless @result[:success]
  }
end

# An IP echo service, which returns your source IP when you access it
# Used for returning the exact source IP when the packet being SNAT
Given /^an IP echo service is setup on the master node and the ip is stored in the#{OPT_SYM} clipboard$/ do | cb_name |
  ensure_admin_tagged

  host = env.master_hosts.first
  cb_name = "ipecho_ip" unless cb_name
  cb[cb_name] = host.local_ip

  @result = host.exec_admin("docker run --name ipecho -d -p 8888:80 quay.io/openshifttest/ip-echo")
  raise "Failed to create the IP echo service." unless @result[:success]
  teardown_add {
    @result = host.exec_admin("docker rm -f ipecho")
    raise "Failed to delete the docker container." unless @result[:success]
  }
end


Given /^the multus is enabled on the cluster$/ do
  ensure_admin_tagged

  desired_multus_replicas = daemon_set('multus', project('openshift-multus')).replica_counters(user: admin)[:desired]
  available_multus_replicas = daemon_set('multus', project('openshift-multus')).replica_counters(user: admin)[:available]
  #storing desired_multus_replicas value in desired_multus_replicas clipboard variable as well
  cb.desired_multus_replicas = desired_multus_replicas
  unless (desired_multus_replicas == available_multus_replicas || desired_multus_replicas > env.nodes.count) && available_multus_replicas != 0
    daemon_set('multus', project('openshift-multus')).describe(admin, quiet:false)
    BushSlicer::Pod.get_labeled("app=multus", user: admin, project: project("openshift-multus", switch: false)) do |pod|
      pod.describe(admin, quiet: false)
    end
    env.nodes(user:admin, refresh: true, quiet: false)
    raise "Multus is not running correctly!"
  end

end

Given /^the status of condition#{OPT_QUOTED} for network operator is :(.+)$/ do | type, status |
  ensure_admin_tagged
  expected_status = status

  if type == "Available"
    @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: "network", o: "jsonpath={.status.conditions[?(.type == \"Available\")].status}")
    real_status = @result[:response]
  elsif type == "Progressing"
    @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: "network", o: "jsonpath={.status.conditions[?(.type == \"Progressing\")].status}")
    real_status = @result[:response]
  elsif type == "Degraded"
    @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: "network", o: "jsonpath={.status.conditions[?(.type == \"Degraded\")].status}")
    real_status = @result[:response]
  else
    raise "Unknown condition type!"
  end

  raise "The status of condition #{type} is incorrect." unless expected_status == real_status
end

Given /^I run command on the#{OPT_QUOTED} node's sdn pod:$/ do |node_name, table|
  ensure_admin_tagged
  network_cmd = table.raw
  node_name ||= node.name
  _admin = admin
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OpenShiftSDN"
    sdn_pod = BushSlicer::Pod.get_labeled("app=sdn", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
      pod.node_name == node_name
    }.first
    cache_resources sdn_pod
    @result = sdn_pod.exec(network_cmd, container: "sdn", as: admin)
  when "OVNKubernetes"
    ovnkube_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
      pod.node_name == node_name
    }.first
    cache_resources ovnkube_pod
    @result = ovnkube_pod.exec(network_cmd, container: "ovn-controller", as: admin)
  else
    raise "unknown network_type"
  end
  # Don't check success here, let the testcase do thad
end

Given /^I restart the ovs pod on the#{OPT_QUOTED} node$/ do | node_name |
  ensure_admin_tagged
  ensure_destructive_tagged
  node_name ||= node.name
  _host = node(node_name).host
  _admin = admin

  # OVS is now running on the host, we have to restart OVS on the host
  if BushSlicer::Platform::SystemdService.enabled?("openvswitch.service", _host)
    logger.info("environment using systemd to launch openvswitch")
    # restarting openvswitch will restart the dependent services ovsdb-server and ovs-vswitchd
    @result = BushSlicer::Platform::SystemdService.new("openvswitch.service", _host).restart
    unless @result[:success]
      raise "Failed to restart the openvswitch service"
    end
  else
    # if we have host openvswitch don't delete the pods because they might fail if ovsdb-server is not active yet
    network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
    network_type = network_operator.network_type(user: admin)
    case network_type
    when "OpenShiftSDN"
      ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
        pod.node_name == node_name
      }.first
    when "OVNKubernetes"
      ovs_pod = BushSlicer::Pod.get_labeled("app=ovs-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
        pod.node_name == node_name
      }.first
    else
      raise "unknown network_type"
    end
    @result = ovs_pod.ensure_deleted(user: _admin)
    unless @result[:success]
      raise "Failed to delete the ovs pod"
    end
  end

end

Given /^the default interface on nodes is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  _admin = admin
  step "I select a random node's host"
  cb_name ||= "interface"
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OVNKubernetes"
    # use -4 to limit output to just `default` interface, fixed in later iproute2 versions
    step %Q/I run command on the node's ovnkube pod:/, table("| ip | -4 | route | show | default |")
  when "OpenShiftSDN"
    step %Q/I run command on the node's sdn pod:/, table("| ip | -4 | route | show | default |")
  else
    raise "unknown network_type"
  end
  # OVN uses `br-ex` and `-` is not a word char, so we have to split on whitespace
  cb[cb_name] = @result[:response].split("\n").first.split[4]
  logger.info "The node's default interface is stored in the #{cb_name} clipboard as #{cb[cb_name]}."
end

Given /^CNI vlan info is obtained on the#{OPT_QUOTED} node$/ do | node_name |
  ensure_admin_tagged
  @result = node(node_name).host.exec_admin("/sbin/bridge -j vlan show")
  raise "Failed to execute bridge vlan show command" unless @result[:success]
  @result[:parsed] = YAML.load @result[:stdout]
end

Given /^the number of bridge PVID (\d+) VLANs matching #{QUOTED} added between the #{SYM} and #{SYM} clipboards is (\d+)$/ do |pvid, mode, clip_a, clip_b, expected_vlans|
  pvid = pvid.to_i
  # RHCOS is Array of VLANs, RHEL7 is a Hash, always convert to Set so we can compare
  added_bridges = cb[clip_b].to_set - cb[clip_a].to_set
  logger.info("added_bridges: #{added_bridges}")
  mode = Regexp.new(mode)
  num_vlans = added_bridges.count { |b|
    # handle old RHEL7 bridge JSON and current RHCOS bridge JSON output
    # RHCOS:
    # [{"ifname":"bridge3","vlans":[{"vlan":1,"flags":["PVID","Egress Untagged"]}]},{"ifname":"veth66451995","vlans":[{"vlan":1,"flags":["PVID","Egress Untagged"]}]}]
    # RHEL7
    # {"bridge3":[{"vlan":1,"flags":["PVID","EgressUntagged"]}],"vethb26eb609":[{"vlan":1,"flags":["PVID","EgressUntagged"]}]}
    # try b[1] first else check for the "vlans" key
    vlans = b[1] || b["vlans"]
    c = vlans.count { |v|
      v["vlan"] == pvid && v["flags"].include?("PVID") && v["flags"].any?(mode)
    }
    c > 0
  }
  if num_vlans != expected_vlans.to_i
    raise "Found #{num_vlans} bridge VLANS of #{pvid} and mode #{mode}, expected #{expected_vlans}"
  end

end

Given /^the bridge interface named "([^"]*)" is deleted from the "([^"]*)" node$/ do |bridge_name, node_name|
  ensure_admin_tagged
  node = node(node_name)
  @result=step "I run command on the node's sdn pod:", table("| bash | -c | if ip addr show #{bridge_name};then ip link delete #{bridge_name};fi |")
  raise "Failed to delete bridge interface" unless @result[:success]
end

Given /^I run command on the#{OPT_QUOTED} node's ovnkube pod:$/ do |node_name, table|
  ensure_admin_tagged
  network_cmd = table.raw
  node_name ||= node.name

  ovnkube_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  cache_resources ovnkube_pod
  @result = ovnkube_pod.exec(network_cmd, as: admin)
  raise "Failed to execute network command!" unless @result[:success]
end

Given /^I run cmds on all ovs pods:$/ do | table |
  ensure_admin_tagged
  network_cmd = table.raw

  # If we have host ovs don't use the pods
  host_ovs = false
  env.nodes.each do |n|
    if BushSlicer::Platform::SystemdService.enabled?("openvswitch.service", n.host)
      logger.info("environment using systemd to launch openvswitch")
      host_ovs ||= true
      @result = n.host.exec_admin(network_cmd.flatten.join(" "))
      raise "Failed to execute network command!" unless @result[:success]
    end
  end
  unless host_ovs
    network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
    network_type = network_operator.network_type(user: admin)
    case network_type
    when "OpenShiftSDN"
      ovs_pods = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin)
    when "OVNKubernetes"
      ovs_pods = BushSlicer::Pod.get_labeled("app=ovs-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin)
    else
      raise "unknown network_type"
    end
    ovs_pods.each do |pod|
      @result = pod.exec(network_cmd, as: admin)
      raise "Failed to execute network command!" unless @result[:success]
    end
  end
end

# WARNING: Starting in 4.6 OVS runs on the host.  This step will detect automatically
Given /^I run command on the#{OPT_QUOTED} node's ovs pod:$/ do |node_name, table|
  ensure_admin_tagged
  network_cmd = table.raw
  node_name ||= node.name

  _admin = admin
  _host = node(node_name).host
  # OVS is now running on the host, we have to restart OVS on the host
  if BushSlicer::Platform::SystemdService.enabled?("openvswitch.service",_host)
    logger.info("environment using systemd to launch openvswitch")
    @result = _host.exec_admin(network_cmd.flatten.join(" "))
  else
    # if we have host openvswitch don't delete the pods because they might fail if ovsdb-server is not active yet
    network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
    network_type = network_operator.network_type(user: admin)
    case network_type
    when "OpenShiftSDN"
      ovs_pod = BushSlicer::Pod.get_labeled("app=ovs", project: project("openshift-sdn", switch: false), user: admin) { |pod, hash|
        pod.node_name == node_name
      }.first
    when "OVNKubernetes"
      ovs_pod = BushSlicer::Pod.get_labeled("app=ovs-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
        pod.node_name == node_name
      }.first
    else
      raise "unknown network_type"
    end
    cache_resources ovs_pod
    @result = ovs_pod.exec(network_cmd, as: admin)
  end
  # Don't check success here, let the testcase do thad
end

Given /^the subnet for primary interface on node is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  cb_name = "subnet_range" unless cb_name

  step "the default interface on nodes is stored in the clipboard"
  step "I run command on the node's sdn pod:", table(
    "| bash | -c | ip -4 -brief a show \"<%= cb.interface %>\" \\| awk '{print $3}' |"
  )
  raise "Failed to get the subnet range for the primary interface on the node" unless @result[:success]
  cb[cb_name] = @result[:stdout].chomp
  logger.info "Subnet range for the primary interface on the node is stored in the #{cb_name} clipboard."
end

Given /^the env is using "([^"]*)" networkType$/ do |network_type|
  ensure_admin_tagged
  _admin = admin
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  raise "the networkType is not #{network_type}" unless network_operator.network_type(user: _admin) == network_type
end

Given /^the env is using windows nodes$/ do
  ensure_admin_tagged
  _admin = admin
  @result = _admin.cli_exec(:get, resource: "nodes", show_label:true)
  raise "env doesn't have any windows node" unless @result[:response].include? "kubernetes.io/os=windows"
end

Given /^the env has hybridOverlayConfig enabled$/ do
  ensure_admin_tagged
  _admin = admin
  @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.ovnKubernetesConfig}")
  raise "env doesn't have hybridOverlayConfig enabled" unless @result[:response].include? "hybridOverlayConfig"
end


Given /^the bridge interface named "([^"]*)" with address "([^"]*)" is added to the "([^"]*)" node$/ do |bridge_name,address,node_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  @result = host.exec_admin("ip link add #{bridge_name} type bridge;ip address add #{address} dev #{bridge_name};ip link set up #{bridge_name}")
  raise "Failed to add  bridge interface" unless @result[:success]
end

Given /^a DHCP service is configured for interface "([^"]*)" on "([^"]*)" node with address range and lease time as "([^"]*)"$/ do |br_inf,node_name,add_lease|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  dhcp_status_timeout = 30
  #Following will take dnsmasq backup and append curl contents to the dnsmasq config after
  logger.info("Logging ARP entries on dnsmasq.conf node which might help in debugging later if required")
  host.exec_admin("arp -a")
  logger.info("Logging last 10 lines of dnsmasq.conf to check if required config is not appended already which might help in debugging later")
  host.exec_admin("tail -10 /etc/dnsmasq.conf")
  @result = host.exec_admin("cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak;curl https://raw.githubusercontent.com/openshift/verification-tests/master/testdata/networking/multus-cni/dnsmasq_for_testbridge.conf | sed s/testbr1/#{br_inf}/g | sed s/88.8.8.100,88.8.8.110,24h/#{add_lease}/g > /etc/dnsmasq.conf;systemctl restart dnsmasq --now")
  raise "Failed to configure dnsmasq service" unless @result[:success]
  wait_for(dhcp_status_timeout) {
    if host.exec_admin("systemctl status dnsmasq")[:response].include? "running"
      logger.info("dnsmasq service is running fine")
    else
      host.exec_admin("cp /etc/dnsmasq.conf.bak /etc/dnsmasq.conf && systemctl restart dnsmasq --now")
      raise "Failed to start dnsmasq service. Check you cluster health manually"
    end
  }
end

Given /^a DHCP service is deconfigured on the "([^"]*)" node$/ do |node_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  dhcp_status_timeout = 30
  #Copying original dnsmasq on to the modified one
  @result = host.exec_admin("systemctl stop dnsmasq;cp /etc/dnsmasq.conf.bak /etc/dnsmasq.conf;systemctl restart dnsmasq --now")
  raise "Failed to configure dnsmasq service" unless @result[:success]
  wait_for(dhcp_status_timeout) {
    if host.exec_admin("systemctl status dnsmasq")[:response].include? "running"
      logger.info("dnsmasq service is running fine")
      host.exec_admin("rm /etc/dnsmasq.conf.bak")
    else
      raise "Failed to start dnsmasq service. Check you cluster health manually"
    end
  }
end

Given /^the vxlan tunnel name of node "([^"]*)" is stored in the#{OPT_SYM} clipboard$/ do |node_name, cb_name|
  ensure_admin_tagged
  cb_name ||= "interface_name"

  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OVNKubernetes"
    cb[cb_name] = "ovn-k8s-mp0"
  when "OpenShiftSDN"
    cb[cb_name] = "tun0"
  else
    raise "unable to find interface name or networkType"
  end
  logger.info "The tunnel interface name is stored in the #{cb_name} clipboard."
end

Given /^the vxlan tunnel address of node "([^"]*)" is stored in the#{OPT_SYM} clipboard$/ do |node_name, cb_address|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  cb_address ||= "interface_address"
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OVNKubernetes"
    inf_name="ovn-k8s-mp0"
    @result = host.exec_admin("ifconfig #{inf_name.split("\n")[0]}")
    cb[cb_address] = @result[:response].match(/\d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}/)[0]
  when "OpenShiftSDN"
    @result = host.exec_admin("ifconfig tun0")
    cb[cb_address] = @result[:response].match(/\d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}/)[0]
  else
    raise "unable to find interface address or networkType"
  end
  logger.info "The tunnel interface address is stored in the #{cb_address} clipboard."
end

Given /^the Internal IP of node "([^"]*)" is stored in the#{OPT_SYM} clipboard$/ do |node_name, cb_ipaddr|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  cb_ipaddr ||= "ip_address"
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OVNKubernetes"
    # use -4 to limit output to just `default` interface, fixed in later iproute2 versions
    step %Q/I run command on the node's ovnkube pod:/, table("| ip | -4 | route | show | default |")
  when "OpenShiftSDN"
    step %Q/I run command on the node's sdn pod:/, table("| ip | -4 | route | show | default |")
  else
    raise "unknown networkType"
  end
  # OVN uses `br-ex` and `-` is not a word char, so we have to split on whitespace
  def_inf = @result[:response].split("\n").first.split[4]
  logger.info "The node's default interface is #{def_inf}"
  @result = host.exec_admin("ip -4 -brief addr show #{def_inf}")
  cb[cb_ipaddr]=@result[:response].match(/\d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}/)[0]
  logger.info "The Internal IP of node is stored in the #{cb_ipaddr} clipboard."
end

Given /^I store "([^"]*)" node's corresponding default networkType pod name in the#{OPT_SYM} clipboard$/ do |node_name, cb_pod_name|
  ensure_admin_tagged
  node_name ||= node.name
  _admin = admin
  cb_pod_name ||= "pod_name"
  @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  raise "Unable to find corresponding networkType pod name" unless @result[:success]
  if @result[:response] == "OpenShiftSDN"
     app="app=sdn"
     project_name="openshift-sdn"
  else
     app="app=ovnkube-node"
     project_name="openshift-ovn-kubernetes"
  end
  cb.network_project_name = project_name
  cb[cb_pod_name] = BushSlicer::Pod.get_labeled(app, project: project(project_name, switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first.name
  logger.info "node's corresponding networkType pod name is stored in the #{cb_pod_name} clipboard as #{cb[cb_pod_name]}."
end

Given /^I store the ovnkube-master#{OPT_QUOTED} leader pod in the#{OPT_SYM} clipboard(?: using node #{QUOTED})?$/ do |ovndb, cb_leader_name, node_name|
  ensure_admin_tagged
  cb_leader_name ||= "#{ovndb}_leader"
  case ovndb
  when "north"
    ovsappctl_cmd = %w(ovs-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound)
  else
    ovsappctl_cmd = %w(ovs-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound)
  end

  if node_name == nil
    # if we don't specify a node pick the oldest pod to check leader status
    ovn_pods = BushSlicer::Pod.get_labeled("app=ovnkube-master", project: project("openshift-ovn-kubernetes", switch: false),
                                           user: admin, quiet: true) { |pod, hash|
      # make sure we pick a Running master
      pod.ready?(user: admin, cached: false, quiet: true)
    }
    # use the oldest ovn_pod, hoping that it is the master
    ovn_pods.sort!{ |a,b| a.props[:created] <=> b.props[:created]}

  else
    ovn_pods = BushSlicer::Pod.get_labeled("app=ovnkube-master", project: project("openshift-ovn-kubernetes", switch: false),
                                           user: admin, quiet: true) { |pod, hash|
      # always make sure it is ready
      pod.node_name == node_name && pod.ready?(user: admin, cached: false, quiet: true)
    }
    # there should be only one pod.
  end

  cluster_state = nil
  ovn_pods.each{ |ovn_pod|
    @result = ovn_pod.exec(*ovsappctl_cmd, as: admin, container: "northd")
    if @result[:success]
      cluster_state = @result[:response].strip
      break
    end
  }
  raise "Failed to execute network command!" unless cluster_state != nil
  # for some reason "oc rsh" output contains CR, so we have to remove them
  leader_id = cluster_state.match(/Leader:\s+(\S+)/)
  if leader_id[1] == "unknown"
    raise "Unknown leader"
  end
  servers = cluster_state.match(/Servers:\n(.*)/m)
  leader_line = servers[1].lines.find { |line| line.include? "(" + leader_id[1] }
  unless leader_line
    raise "Unable to find leader #{leader_id[1]}"
  end
  splits = leader_line.match(/\((\S+)[^:]+:([^:]+):(\d+)\)/)
  leader_node = splits.captures[1]
  leader_pod = BushSlicer::Pod.get_labeled("app=ovnkube-master", project: project("openshift-ovn-kubernetes", switch: false),
                                           user: admin, quiet: true) { |pod, hash|
    pod.node_name == leader_node || pod.ip == leader_node
  }.first
  # update the cache so we can execute on the pod without specify the name
  cache_resources leader_pod
  cb[cb_leader_name] = leader_pod
  logger.info "cb.#{cb_leader_name}.name = #{leader_pod.name}"
  logger.info "cb.#{cb_leader_name}.node_name = #{leader_pod.node_name}"
end

# work-around nested clipboard Transform <% cb.south_leader.name %> issues by combining this step
Given /^admin deletes the ovnkube-master#{OPT_QUOTED} leader$/ do |ovndb|
  ensure_admin_tagged

  cb_leader_name ||= "#{ovndb}_leader"
  if cb[cb_leader_name] == nil
    step %Q/I store the ovnkube-master "#{ovndb}" leader pod in the :#{cb_leader_name} clipboard/
  end
  leader_pod_name = cb[cb_leader_name].name
  # this doens't work for some reason, can't find the dynamic step
  # step %Q/Given admin ensures "#{leader_pod_name}" pod is deleted from the "openshift-ovn-kubernetes" project/

  @result = resource(leader_pod_name, "pod", project_name: "openshift-ovn-kubernetes").ensure_deleted(user: admin, wait: 300)
end

Given /^the OVN "([^"]*)" database is killed on the "([^"]*)" node$/ do |ovndb, node_name|
  ensure_admin_tagged
  node = node(node_name)
  host = node.host
  case ovndb
  when "north"
    kill_match = "OVN_Northbound"
  else
    kill_match = "OVN_Southbound"
  end
  @result = host.exec_admin("pkill -f #{kill_match}")
  raise "Failed to kill the #{ovndb} database daemon" unless @result[:success]
end

Given /^OVN is functional on the cluster$/ do
  ensure_admin_tagged
  ovnkube_node_ds = daemon_set('ovnkube-node', project('openshift-ovn-kubernetes')).replica_counters(user: admin, cached: false)
  ovnkube_master_ds = daemon_set('ovnkube-master', project('openshift-ovn-kubernetes')).replica_counters(user: admin, cached: false)
  desired_ovnkube_node_replicas, available_ovnkube_node_replicas = ovnkube_node_ds.values_at(:desired, :available)
  desired_ovnkube_master_replicas, available_ovnkube_master_replicas = ovnkube_master_ds.values_at(:desired, :available)

  raise "OVN is not running correctly! Check one of your ovnkube-node pod" unless desired_ovnkube_node_replicas == available_ovnkube_node_replicas && available_ovnkube_node_replicas != 0
  raise "OVN is not running correctly! Check one of your ovnkube-master pod" unless desired_ovnkube_master_replicas == available_ovnkube_master_replicas && available_ovnkube_master_replicas != 0
end

Given /^I enable multicast for the "(.+?)" namespace$/ do | project_name |
  ensure_admin_tagged
  _admin = admin
  @result = _admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  raise "Unable to find corresponding networkType pod name" unless @result[:success]
  if @result[:response] == "OpenShiftSDN"
    annotation = 'netnamespace.network.openshift.io/multicast-enabled=true'
    space = 'netnamespace'
  else
    annotation = 'k8s.ovn.org/multicast-enabled=true'
    space = 'namespace'
  end
  @result = admin.cli_exec(:annotate, resource: space, resourcename: project_name, keyval: annotation)
  unless @result[:success]
    raise "Failed to apply the default deny annotation to specified namespace."
  end
  logger.info "The multicast is enable in the #{project_name} project"
end

Given /^I get the ptp logs of the "([^"]*)" node since "(.+)" ago$/ do | node_name, duration |
  ensure_admin_tagged
  node_name ||= node.name

  # Only return logs newer than a relative duration like 5s, 2m, or 3h.
  ptp_pod = BushSlicer::Pod.get_labeled("app=linuxptp-daemon", project: project("openshift-ptp", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  @result = admin.cli_exec(:logs, resource_name: ptp_pod.name, n: "openshift-ptp", since: duration)
end

Given /^the ptp operator is running well$/ do
  ensure_admin_tagged
  step %Q/I switch to cluster admin pseudo user/

  unless project('openshift-ptp').exists?
    if env.version_eq("4.3", user: user) || env.version_eq("4.4", user: user)
      ns = "ns43.yaml"
      dr = "43"
    elsif env.version_ge("4.5", user: user)
      ns = "ns45.yaml"
      dr = "45"
    end
    step %Q{I obtain test data file "networking/ptp/namespace/#{dr}/#{ns}"}
    step %Q/I run the :create admin command with:/,table(%{
      | f | #{ns} |
    })
    step %Q{the step should succeed}
  end

  step %Q/I use the "openshift-ptp" project/
  unless operator_group('ptp-operators').exists?
    step %Q{I obtain test data file "networking/ptp/og/og.yaml"}
    step %Q/I run the :create admin command with:/,table(%{
      | f | og.yaml |
    })
    step %Q{the step should succeed}
  end

  unless subscription('openshift-ptp').exists?
    step %Q/evaluation of `cluster_version('version').channel.split('-')[1]` is stored in the :ocp_cluster_version clipboard/
    step %Q{I obtain test data file "networking/ptp/subscription/sub.yaml"}
    step %Q/I run oc create over "sub.yaml" replacing paths:/,table(%{
      | ["spec"]["channel"] | "#{cb.ocp_cluster_version}" |
    })
    step %Q{the step should succeed}
  end

  step %Q/ptp operator is ready/
  step %Q/ptp config daemon is ready/
end

Given /^ptp operator is ready$/ do
  ensure_admin_tagged
  project("openshift-ptp")
  step %Q/a pod becomes ready with labels:/, table(%{
    | name=ptp-operator |
  })
end

Given /^ptp config daemon is ready$/ do
  ensure_admin_tagged
  project("openshift-ptp")
  step %Q/a pod becomes ready with labels:/, table(%{
    | app=linuxptp-daemon |
  })
end

Given /^I install machineconfigs load-sctp-module$/ do
  ensure_admin_tagged
  _admin = admin
  if cb.workers.count > 1
    @result = _admin.cli_exec(:get, resource: "machineconfigs", output: 'jsonpath={.items[?(@.metadata.name=="load-sctp-module")].metadata.name}')
    if @result[:response] != "load-sctp-module"
      @result = _admin.cli_exec(:create, f: "#{BushSlicer::HOME}/testdata/networking/sctp/load-sctp-module.yaml")
      raise "Failed to install load-sctp-module" unless @result[:success]
    end
  else
    raise "At least two schedulable workers are needed"
  end
end

Given /^I check load-sctp-module in all workers$/ do
  ensure_admin_tagged
  _admin = admin
  cb.workers.each do |workers|
    @result = workers.host.exec_admin("cat /sys/module/sctp/initstate")
    unless @result[:response].include? "live"
      raise "No sctp module installed"
    end
  end
end

Given /^the node's MTU value is stored in the#{OPT_SYM} clipboard$/ do |cb_node_mtu|
  ensure_admin_tagged
  cb_node_mtu = "mtu" unless cb_node_mtu
  @result = admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  if @result[:success] then
     networkType = @result[:response].strip
  end
  raise "Failed to get networkType" unless @result[:success]
  if @result[:response] == "OVNKubernetes"
     step %Q/I run command on the node's ovnkube pod:/, table("| bash | -c | ip route show default |")
  else
     step %Q/I run command on the node's sdn pod:/, table("| bash | -c | ip route show default |")
  end
  # OVN uses `br-ex` and `-` is not a word char, so we have to split on whitespace
  inf_name = @result[:response].split("\n").first.split[4]
  @result = host.exec_admin("ip a show #{inf_name}")
  cb[cb_node_mtu] = @result[:response].split(/mtu /)[1][0,4]
  logger.info "Node's MTU value is stored in the #{cb_node_mtu} clipboard as #{cb[cb_node_mtu]}."
end

Given /^the mtu value "([^"]*)" is patched in CNO config according to the networkType$/ do | mtu_value |
  ensure_admin_tagged
  mtu_value ||= "mtu_value"
  @result = admin.cli_exec(:get, resource: "network.operator", output: "jsonpath={.items[*].spec.defaultNetwork.type}")
  if @result[:response] == "OVNKubernetes"
     config_var = "ovnKubernetesConfig"
  else
     config_var = "openshiftSDNConfig"
  end
  @result = admin.cli_exec(:patch, resource: "network.operator", resource_name: "cluster", p: "{\"spec\":{\"defaultNetwork\":{\"#{config_var}\":{\"mtu\": #{mtu_value}}}}}", type: "merge")
  raise "Failed to patch CNO!" unless @result[:success]

  teardown_add {
      @result = admin.cli_exec(:patch, resource: "network.operator", resource_name: "cluster", p: "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"mtu\": null}}}}", type: "merge")
      raise "Failed to clear mtu field from CNO" unless @result[:success]
  }
end

Given /^I save egress data file directory to the#{OPT_SYM} clipboard$/ do | cb_name |
  ensure_admin_tagged
  cb_name = "cb_egress_directory" unless cb_name
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OVNKubernetes"
    cb[cb_name]="ovn-egressfirewall"
  when "OpenShiftSDN"
    cb[cb_name]="egressnetworkpolicy"
  else
    raise "unknown network_type"
  end
  logger.info "The egressfirewall file directory path is stored to the #{cb_name} clipboard."
end

Given /^I save egress type to the#{OPT_SYM} clipboard$/ do | cb_name |
  ensure_admin_tagged
  cb_name = "cb_egress_type" unless cb_name
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  network_type = network_operator.network_type(user: admin)
  case network_type
  when "OVNKubernetes"
    cb[cb_name] = "egressfirewall"
  when "OpenShiftSDN"
    cb[cb_name] = "egressnetworkpolicy"
  else
    raise "unknown network_type"
  end
  logger.info "The egressfirewall type is stored to the #{cb_name} clipboard."
end

# ipecho service is used for retrieve the source IP from the outbound traffic of the cluster
# It is used for egress IP testing. Currently it is installed in a VM in vmc network.
# Huiran Wang
Given /^I save ipecho url to the#{OPT_SYM} clipboard$/ do | cb_name |
  ensure_admin_tagged
  cb_name = "ipecho_url" unless cb_name
  cb[cb_name]="172.31.249.80:9095"
  logger.info "The ipecho service url #{cb[cb_name]} is stored to the #{cb_name} clipboard."
end

Given /^the IPsec is enabled on the cluster$/ do
  ensure_admin_tagged
  _admin = admin
  network_operator = BushSlicer::NetworkOperator.new(name: "cluster", env: env)
  default_network = network_operator.default_network(user: admin)
  raise "env doesn't have IPSec enabled" unless default_network["ipsecConfig"]
end

Given /^the node's active nmcli connection is stored in the#{OPT_SYM} clipboard$/ do |cb_name|
  ensure_admin_tagged
  cb_name = "active_con_uuid" unless cb_name
  @result = host.exec_admin("nmcli -t -f UUID c show --active")
  # run command and store first line of output as the response
  cb[cb_name] = @result[:response].split("\n").first
  logger.info "Node's active nmcli connection uuid is stored in the #{cb_name} clipboard as #{cb[cb_name]}"
end

Given /^I store the hostname from external ids in the#{OPT_SYM} clipboard on the "([^"]*)" node$/ do |cb_ovn_hostname, node_name|
  ensure_admin_tagged
  node_name ||= node.name
  cb_ovn_hostname ||= "ovn_hostname"

  ovsvsctl_cmd = %w(ovs-vsctl list open .)
  ovn_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  @result = ovn_pod.exec(*ovsvsctl_cmd, as: admin, container: "ovnkube-node")
  if @result[:success]
    ovn_state_output = @result[:response].strip
  end
  raise "Failed to execute network command!" unless ovn_state_output != nil
  cb[cb_ovn_hostname] = ovn_state_output.split("hostname=").last.split(", ovn-bridge-mappings").first
  logger.info "nodes's corresponding hostname from external_ids is stored in the #{cb_ovn_hostname} clipboard."
end

Given /^I store the#{OPT_QUOTED} hostname in the#{OPT_SYM} clipboard for the "([^"]*)" node$/ do |type_name,cb_type_hostname,node_name|
  ensure_admin_tagged
  node_name ||= node.name
  cb_type_hostname ||= "type_hostname"
  case type_name
  when "short"
    ovn_cmd = %w(hostname -s)
  else
    ovn_cmd = %w(hostname -f)
  end

  ovn_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  @result = ovn_pod.exec(*ovn_cmd, as: admin, container: "ovnkube-node")
  if @result[:success]
     hostname_result = @result[:response].lines.first.strip
  end
  raise "Failed to execute network command!" unless hostname_result != nil
  cb[cb_type_hostname] = hostname_result
  logger.info "nodes's corresponding #{type_name} hostname is stored in the #{cb_type_hostname}"
end

Given /^I set#{OPT_QUOTED} hostname to external ids on the "([^"]*)" node$/ do |custom_hostname,node_name|
  ensure_admin_tagged
  node_name ||= node.name

  # set hostname to external ids
  ovsvsctl_cmd = %w(ovs-vsctl set open .)
  external_hostname = "external_ids:hostname=#{custom_hostname}"
  ovsvsctl_cmd << external_hostname
  ovn_pod = BushSlicer::Pod.get_labeled("app=ovnkube-node", project: project("openshift-ovn-kubernetes", switch: false), user: admin) { |pod, hash|
    pod.node_name == node_name
  }.first
  @result = ovn_pod.exec(*ovsvsctl_cmd, as: admin, container: "ovnkube-node")
  if @result[:success]
    logger.info "Set the ${custom_hostname} to ovn external_ids successfully."
  else
    raise "Set the ${custom_hostname} to ovn external_ids failed."
  end
end
