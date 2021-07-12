Feature: Pod related networking scenarios

  # @author bmeng@redhat.com
  # @case_id OCP-9747
  @admin
  Scenario: Pod cannot claim UDP port 4789 on the node as part of a port mapping
    Given I have a project
    And SCC "privileged" is added to the "system:serviceaccounts:<%= project.name %>" group
    Given I obtain test data file "networking/pod_with_udp_port_4789.json"
    When I run the :create client command with:
      | f | pod_with_udp_port_4789.json |
    Then the step should succeed
    Given the pod named "hello-pod" status becomes :pending
    And I wait up to 30 seconds for the steps to pass:
    """
    When I run the :describe client command with:
      | resource      | pod   |
    Then the output should contain "address already in use"
    """

  # @author yadu@redhat.com
  # @case_id OCP-10031
  @smoke
  Scenario: Container could reach the dns server
    Given I have a project
    Given I obtain test data file "pods/ocp10031/pod.json"
    When I run the :create client command with:
      | f | pod.json |
    And the pod named "hello-pod" becomes ready
    And I run the steps 20 times:
    """
    Given I execute on the pod:
      | getent | hosts | google.com |
    Then the step should succeed
    And the output should contain "google.com"
    """

  # @author yadu@redhat.com
  # @case_id OCP-14986
  @admin
  Scenario: The openflow list will be cleaned after delete the pods
    Given I have a project
    Given I have a pod-for-ping in the project
    Then evaluation of `pod.node_name` is stored in the :node_name clipboard
    Then evaluation of `pod.ip` is stored in the :pod_ip clipboard
    When I run command on the "<%= cb.node_name %>" node's sdn pod:
      | ovs-ofctl| -O | openflow13 | dump-flows | br0 |
    Then the step should succeed
    And the output should contain:
      | <%=cb.pod_ip %> |
    When I run the :delete client command with:
      | object_type       | pod       |
      | object_name_or_id | hello-pod |
    Then the step should succeed
    Given I wait up to 10 seconds for the steps to pass:
    """
    When I run command on the "<%= cb.node_name %>" node's sdn pod:
      | ovs-ofctl| -O | openflow13 | dump-flows | br0 |
    Then the step should succeed
    And the output should not contain:
      | <%=cb.pod_ip %> |
    """

  # @author bmeng@redhat.com
  # @case_id OCP-10817
  @admin
  Scenario: Check QoS after creating pod
    Given I have a project
    # setup iperf server to receive the traffic
    Given I obtain test data file "networking/egress-ingress/qos/iperf-server.json"
    When I run the :create client command with:
      | f | iperf-server.json |
    Then the step should succeed
    And the pod named "iperf-server" becomes ready
    And evaluation of `pod.ip` is stored in the :iperf_server clipboard

    # setup iperf client to send traffic to server with qos configured
    Given I obtain test data file "networking/egress-ingress/qos/iperf-rc.json"
    When I run oc create over "iperf-rc.json" replacing paths:
      | ["spec"]["template"]["metadata"]["annotations"]["kubernetes.io/ingress-bandwidth"] | 5M |
      | ["spec"]["template"]["metadata"]["annotations"]["kubernetes.io/egress-bandwidth"] | 2M |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=iperf-pods |
    And evaluation of `pod.name` is stored in the :iperf_client clipboard
    And evaluation of `pod.node_name` is stored in the :node_name clipboard

    # check the ovs port and interface for the qos availibility
    When I run command on the "<%= cb.node_name %>" node's sdn pod:
      | ovs-vsctl | list | qos |
    Then the step should succeed
    And the output should contain "max-rate="5000000""
    When I run command on the "<%= cb.node_name %>" node's sdn pod:
      | ovs-vsctl | list | interface |
    Then the step should succeed
    And the output should contain "ingress_policing_rate: 1953"

    # test the bandwidth limit with qos for egress
    When I execute on the "<%= cb.iperf_client %>" pod:
      | sh | -c | iperf3 -c <%= cb.iperf_server %> -i 1 -t 12s |
    Then the step should succeed
    And the expression should be true> @result[:response].scan(/[12].[0-9][0-9] Mbits/).size >= 10
    # test the bandwidth limit with qos for ingress
    When I execute on the "<%= cb.iperf_client %>" pod:
      | sh | -c | iperf3 -c <%= cb.iperf_server %> -i 1 -t 12s -R |
    Then the step should succeed
    And the expression should be true> @result[:response].scan(/[45].[0-9][0-9] Mbits/).size >= 10

    # remove the qos pod and check if the ovs qos configurations are removed
    When I run the :delete client command with:
      | object_type | replicationcontrollers |
      | object_name_or_id | iperf-rc |
    Then the step should succeed
    And I wait for the resource "pod" named "<%= cb.iperf_client %>" to disappear

    When I run command on the "<%= cb.node_name %>" node's sdn pod:
      | ovs-vsctl | list | qos |
    Then the step should succeed
    And the output should not contain "max-rate="5000000""
    When I run command on the "<%= cb.node_name %>" node's sdn pod:
      | ovs-vsctl | list | interface |
    Then the step should succeed
    And the output should not contain "ingress_policing_rate: 1953"

  # @author anusaxen@redhat.com
  # @case_id OCP-23890
  @admin
  Scenario: A pod with or without hostnetwork cannot access the MCS port 22623 or 22624 on the master
    Given I store the masters in the :masters clipboard
    And the Internal IP of node "<%= cb.masters[0].name %>" is stored in the :master_ip clipboard
    Given I select a random node's host
    Given I have a project
    #pod-for-ping will be a non-hostnetwork pod
    And SCC "privileged" is added to the "system:serviceaccounts:<%= project.name %>" group
    And I have a pod-for-ping in the project

    When I execute on the pod:
      | curl | -I | https://<%= cb.master_ip %>:22623/config/master | -k |
    Then the output should contain "Connection refused"
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_ip %>:22624/config/master | -k |
    Then the output should contain "Connection refused"

    #hostnetwork-pod will be a hostnetwork pod
    Given I obtain test data file "networking/hostnetwork-pod.json"
    When I run the :create admin command with:
      | f | hostnetwork-pod.json |
      | n | <%= project.name %>                                                                                |
    Then the pod named "hostnetwork-pod" becomes ready
    #Pods should not access the MCS port 22623 or 22624 on the master
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_ip %>:22623/config/master | -k |
    Then the output should contain "Connection refused"
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_ip %>:22624/config/master | -k |
    Then the output should contain "Connection refused"

  # @author anusaxen@redhat.com
  # @case_id OCP-23891
  @admin
  Scenario: A pod cannot access the MCS port 22623 or 22624 via the SDN/tun0 address of the master
    Given I store the masters in the :masters clipboard
    And the vxlan tunnel address of node "<%= cb.masters[0].name %>" is stored in the :master_tunnel_address clipboard
    Given I select a random node's host
    And I have a project
    #pod-for-ping will be a non-hostnetwork pod
    And I have a pod-for-ping in the project
    #Curl on Master's tun0/k8s-x-x- IP to make sure connections are blocked to MCS via tun0
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_tunnel_address %>:22623/config/master | -k |
    Then the output should contain "Connection refused"
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_tunnel_address %>:22624/config/master | -k |
    Then the output should contain "Connection refused"

  # @author anusaxen@redhat.com
  # @case_id OCP-23893
  @admin
  Scenario: A pod in a namespace with an egress IP cannot access the MCS
    Given I store the masters in the :masters clipboard
    And the Internal IP of node "<%= cb.masters[0].name %>" is stored in the :master_ip clipboard
    Given I select a random node's host
    And evaluation of `node.name` is stored in the :egress_node clipboard
    #add the egress ip to the hostsubnet
    And the valid egress IP is added to the "<%= cb.egress_node %>" node
    Given I have a project
    And evaluation of `project.name` is stored in the clipboard
    # add the egress ip to the project
    When I run the :patch admin command with:
    | resource      | netnamespace                         |
    | resource_name | <%= project.name %>                    |
    | p             | {"egressIPs":["<%= cb.valid_ip %>"]} |
    | type          | merge                                |
    Then the step should succeed
    #pod-for-ping will be a non-hostnetwork pod
    And I have a pod-for-ping in the project

    #Pod cannot access MCS
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_ip %>:22623/config/master | -k |
    Then the output should contain "Connection refused"
    When I execute on the pod:
      | curl | -I | https://<%= cb.master_ip %>:22624/config/master | -k |
    Then the output should contain "Connection refused"

  # @author anusaxen@redhat.com
  # @case_id OCP-23894
  @admin
  Scenario: User cannot access the MCS by creating a service that maps to non-MCS port to port 22623 or 22624 on the IP of a master (via manually-created ep's)
    Given I store the masters in the :masters clipboard
    And the Internal IP of node "<%= cb.masters[0].name %>" is stored in the :master_ip clipboard
    Given I have a project
    #pod-for-ping will be a non-hostnetwork pod
    And I have a pod-for-ping in the project
    #Exposing above pod to MCS target port 22623
    When I run the :expose client command with:
      | resource      | pod                     |
      | resource_name | <%= cb.ping_pod.name %> |
      | target_port   | 22623                   |
      | port          | 8080                    |
    Then the step should succeed
    # Editing endpoint created above during expose to point to master ip and the step should fail
    When I run the :patch client command with:
      | resource      | ep                                                            						   |
      | resource_name | <%= cb.ping_pod.name %>                                       						   |
      | p             | {"subsets": [{"addresses": [{"ip": "<%= cb.master_ip %>"}],"ports": [{"port": 22623,"protocol": "TCP"}]}]} |
      | type          | merge                                                         						   |
    Then the step should fail
    And the output should contain "endpoints "<%= cb.ping_pod.name %>" is forbidden: endpoint port TCP:22623 is not allowed"

  # @author anusaxen@redhat.com
  # @case_id OCP-21846
  @admin
  @destructive
  Scenario: ovn pod can be scheduled even if the node taint to unschedule
    Given the env is using "OVNKubernetes" networkType
    And I store all worker nodes to the :nodes clipboard
    #Tainting all worker nodes to NoSchedule
    When I run the :oadm_taint_nodes admin command with:
      | l         | node-role.kubernetes.io/worker |
      | key_val   | key21846=value2:NoSchedule     |
    Then the step should succeed
    And I register clean-up steps:
    """
    I run the :oadm_taint_nodes admin command with:
      | l         | node-role.kubernetes.io/worker |
      | key_val   | key21846-                      |
    Then the step should succeed
    """
    Given I have a project
    #Makng sure test pods can't be scheduled on any of worker node
    Given I obtain test data file "networking/pod-for-ping.json"
    And I run the :create client command with:
      | f | pod-for-ping.json |
    Then the step should succeed
    And the pod named "hello-pod" status becomes :pending within 60 seconds
    #Getting ovnkube pod name from any of worker node
    When I run the :get admin command with:
      | resource      | pod                                   |
      | fieldSelector | spec.nodeName=<%= cb.nodes[0].name %> |
      | n             | openshift-ovn-kubernetes              |
      | o             | jsonpath={.items[*].metadata.name}    |
    Then the step should succeed
    And evaluation of `@result[:response]` is stored in the :ovnkube_pod_name clipboard
    And admin ensures "<%= cb.ovnkube_pod_name %>" pod is deleted from the "openshift-ovn-kubernetes" project
    #Waiting up to 60 seconds for new ovnkube pod to get created and running on the same node where it was deleted before
    And I wait up to 60 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource      | pod                                   |
      | fieldSelector | spec.nodeName=<%= cb.nodes[0].name %> |
      | n             | openshift-ovn-kubernetes              |
    Then the step should succeed
    And the output should contain "Running"
    """

  # @author anusaxen@redhat.com
  # @case_id OCP-26822
  @admin
  Scenario: [4.x] Conntrack rule for UDP traffic should be removed when the pod for NodePort service deleted
    Given I store the workers in the :nodes clipboard
    And the Internal IP of node "<%= cb.nodes[0].name %>" is stored in the :node_ip clipboard
    Given I have a project
    #privileges are needed to support network-pod as hostnetwork pod creation later
    And SCC "privileged" is added to the "system:serviceaccounts:<%= project.name %>" group
    Given I obtain test data file "networking/pod_with_udp_port_4789_nodename.json"
    When I run oc create over "pod_with_udp_port_4789_nodename.json" replacing paths:
      | ["items"][0]["spec"]["template"]["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed
    Given a pod becomes ready with labels:
      | name=udp-pods |
    And evaluation of `pod` is stored in the :host_pod1 clipboard

    #Using node port to expose the service on port 8080 on the node IP address
    When I run the :expose client command with:
      | resource      | pod                      |
      | resource_name | <%= cb.host_pod1.name %> |
      | type          | NodePort                 |
      | port          | 8080                     |
      | protocol      | UDP                      |
    Then the step should succeed
    #Getting nodeport value
    And evaluation of `service(cb.host_pod1.name).node_port(port: 8080)` is stored in the :nodeport clipboard
    #Creating a simple client pod to generate traffic from it towards the exposed node IP address
    Given I obtain test data file "networking/aosqe-pod-for-ping.json"
    When I run oc create over "aosqe-pod-for-ping.json" replacing paths:
      | ["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed
    Given a pod becomes ready with labels:
      | name=hello-pod |
    And evaluation of `pod` is stored in the :client_pod clipboard
    # The 3 seconds mechanism via for loop will create an Assured conntrack entry which will give us enough time to validate upcoming steps
    When I run the :exec background client command with:
      | pod              | <%= cb.client_pod.name %>                                                                |
      | oc_opts_end      |                                                                                          |
      | exec_command     | bash                                                                                     |
      | exec_command_arg | -c                                                                                       |
      | exec_command_arg | for n in {1..3}; do echo $n; sleep 1; done>/dev/udp/<%= cb.node_ip %>/<%= cb.nodeport %> |
    Then the step should succeed

    #Creating network test pod to levearage conntrack tool
    Given I obtain test data file "networking/net_admin_cap_pod.yaml"
    When I run oc create over "net_admin_cap_pod.yaml" replacing paths:
      | ["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed
    Given a pod becomes ready with labels:
      | name=network-pod |
    And evaluation of `pod.name` is stored in the :network_pod clipboard
    Given I wait up to 20 seconds for the steps to pass:
    """
    And I execute on the pod:
      | bash | -c | conntrack -L \| grep "<%= cb.nodeport %>" |
    Then the step should succeed
    And the output should contain:
      |<%= cb.host_pod1.ip %>|
    """

    #Deleting the udp listener pod which will trigger a new udp listener pod with new IP
    Given I ensure "<%= cb.host_pod1.name %>" pod is deleted
    And a pod becomes ready with labels:
      | name=udp-pods |
    And evaluation of `pod` is stored in the :host_pod2 clipboard

    # The 3 seconds mechanism via for loop will create an Assured conntrack entry which will give us enough time to validate upcoming steps
    When I run the :exec background client command with:
      | pod              | <%= cb.client_pod.name %>                                                                |
      | oc_opts_end      |                                                                                          |
      | exec_command     | bash                                                                                     |
      | exec_command_arg | -c                                                                                       |
      | exec_command_arg | for n in {1..3}; do echo $n; sleep 1; done>/dev/udp/<%= cb.node_ip %>/<%= cb.nodeport %> |
    Then the step should succeed
    #Making sure that the conntrack table should not contain old deleted udp listener pod IP entries but new pod one's
    Given I wait up to 20 seconds for the steps to pass:
    """
    When I execute on the "<%= cb.network_pod %>" pod:
      | bash | -c | conntrack -L \| grep "<%= cb.nodeport %>" |
    Then the output should contain "<%= cb.host_pod2.ip %>"
    And the output should not contain "<%= cb.host_pod1.ip %>"
    """

  # @author anusaxen@redhat.com
  # @case_id OCP-25294
  @admin
  Scenario: Pod should be accesible via node ip and host port
    Given I store the workers in the :workers clipboard
    And the Internal IP of node "<%= cb.workers[0].name %>" is stored in the :worker0_ip clipboard
    And the Internal IP of node "<%= cb.workers[1].name %>" is stored in the :worker1_ip clipboard
    And I have a project
    Given I obtain test data file "networking/pod-for-ping-with-hostport.yml"
    When I run oc create as admin over "pod-for-ping-with-hostport.yml" replacing paths:
      | ["metadata"]["namespace"] |  <%= project.name %>       |
      | ["spec"]["nodeName"]      |  <%= cb.workers[0].name %> |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=hello-pod |
    #Pod should be accesible via node ip and host port from its home node
    Given I use the "<%= cb.workers[0].name %>" node
    And I run commands on the host:
      | curl <%= cb.worker0_ip %>:9500 |
    Then the output should contain:
      | Hello OpenShift |
    #Pod should be accesible via node ip and host port from another node as well. Remember worker0 is home node for that pod
    Given I use the "<%= cb.workers[1].name %>" node
    And I run commands on the host:
      | curl <%= cb.worker0_ip %>:9500 |
    Then the output should contain:
      | Hello OpenShift |

  # @author anusaxen@redhat.com
  # @case_id OCP-26373
  @admin
  @destructive
  Scenario: Make sure the route to ovn tunnel for Node's Pod CIDR gets created in both hybrid/non-hybrid mode
  Given the env is using "OVNKubernetes" networkType
  And I select a random node's host
  And the vxlan tunnel name of node "<%= node.name %>" is stored in the :tunnel_inf_name clipboard
  #Enabling hybrid overlay on the cluster
  Given as admin I successfully merge patch resource "networks.operator.openshift.io/cluster" with:
    | {"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"hybridOverlayConfig":{"hybridClusterNetwork":[{"cidr":"10.132.0.0/14","hostPrefix":23}]}}}}} |
  #Cleanup for bringing CRD to original
  Given I register clean-up steps:
  """
  as admin I successfully merge patch resource "networks.operator.openshift.io/cluster" with:
    | {"spec":{"defaultNetwork":{"ovnKubernetesConfig": null}}} |
  """
  Given I switch to cluster admin pseudo user
  And I use the "openshift-ovn-kubernetes" project
  And all pods in the project are ready
  #Checking hybrid overlay annotation and fetching Pod subnet CIDR
  When I run the :describe client command with:
    | resource | node             |
    | name     | <%= node.name %> |
  Then the step should succeed
  And the output should contain "k8s.ovn.org/hybrid-overlay-node-subnet:"
  And evaluation of `@result[:response].match(/k8s.ovn.org\/hybrid-overlay-node-subnet: \d{1,3}\.\d{1,3}.\d{1,3}.\d{1,3}\/\d{2}/)[0].split(": ")[1]` is stored in the :pod_cidr clipboard
  And I run commands on the host:
    | ip route |
  Then the output should contain:
    | <%= cb.pod_cidr %> dev <%= cb.tunnel_inf_name %> |

  # @author anusaxen@redhat.com
  # @case_id OCP-26014
  @admin
  @destructive
  Scenario: Pod readiness check for OVN
    Given the env is using "OVNKubernetes" networkType
    And OVN is functional on the cluster
    Given I switch to cluster admin pseudo user
    And I use the "openshift-ovn-kubernetes" project
    And a pod is present with labels:
      | app=ovnkube-node |
    #Removing CNI config file from container to check readiness probe functionality
    When I run the :exec client command with:
      | pod              | <%= pod.name %>                       |
      | c                | ovnkube-node                          |
      | oc_opts_end      |                                       |
      | exec_command     | rm                                    |
      | exec_command_arg | /etc/cni/net.d/10-ovn-kubernetes.conf |
    Then the step should succeed
    #Deleting ovnkube-pod will force CNO to rewrite the conf file and bring cluster back to normal after scenario
    And admin ensures "<%= pod.name %>" pod is deleted from the "openshift-ovn-kubernetes" project after scenario
    #Now make sure readiness probe checking above file will cause one of the two ovnkube-node containers to go down and container ready status change to false
    Given I wait up to 30 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource      | pod                                                                     |
      | resource_name | <%= pod.name %>                                                         |
      | o             | jsonpath='{.status.containerStatuses[?(@.name=="ovnkube-node")].ready}' |
    Then the step should succeed
    And the output should contain "false"
    """
    #Making sure the cluster is in good state before exiting from this scenario
    And I wait up to 60 seconds for the steps to pass:
    """
    OVN is functional on the cluster
    """
  # @author anusaxen@redhat.com
  # @case_id OCP-33413
  @admin
  @destructive
  Scenario: xt_u32 kernel module functionality check from NET_ADMIN pods
    Given I have a project
    And I have a pod-for-ping in the project
    Then evaluation of `pod.name` is stored in the :client_pod clipboard
    Given I store the masters in the :masters clipboard
    And I use the "<%= cb.masters[0].name %>" node
    #Making sure the iptables on latest centos are actually nf_tables as the xt_u32 is only supported with that
    When I run commands on the host:
      | iptables --version |
    Then the step should succeed
    Then the output should contain "nf_tables"

    Given I obtain test data file "networking/centos_latest_admin.yaml"
    When I run oc create as admin over "centos_latest_admin.yaml" replacing paths:
      | ["metadata"]["name"]      | server-pod                |
      | ["metadata"]["namespace"] | <%= project.name %>       |
      | ["spec"]["nodeName"]      | <%= cb.masters[0].name %> |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=centos-pod |
    Then evaluation of `pod` is stored in the :server_pod clipboard
    #Enabling XT_u32 module on server pod's node
    And I run commands on the host:
      | modprobe xt_u32 |
    Then the step should succeed

    #Checking whether server pod also has nf_tables version installed
    When admin executes on the "<%= cb.server_pod.name %>" pod:
      | bash | -c | iptables --version |
    Then the step should succeed
    And the output should contain "nf_tables"

    #Creating iptable rule on server pod with module u32 and Successful pings will represent a successful xt_u32 match
    Given admin executes on the "<%= cb.server_pod.name %>" pod:
      | bash | -c | iptables -t filter -A INPUT -i eth0 -m u32 --u32 '6 & 0xFF = 1 && 4 & 0x3FFF = 0 && 0 >> 22 & 0x3C @ 0 >> 24 = 8' |
    Then the step should succeed
    When I execute on the "<%= cb.client_pod %>" pod:
      | ping |-s 2000 | -c1 | <%= cb.server_pod.ip %> |
    Then the step should succeed

    #Successful pings will represent a successful xt_u32 match. Here we allow ping for less than 256 bytes packet else Reject
    Given admin executes on the "<%= cb.server_pod.name %>" pod:
      | bash | -c | iptables -t filter -A INPUT -i eth0 -m u32 --u32 '0 & 0xFFFF = 0x100:0xFFFF' -j REJECT |
    Then the step should succeed
    When I execute on the "<%= cb.client_pod %>" pod:
      | ping | -s 64 |-c1 | <%= cb.server_pod.ip %> |
    Then the step should succeed
    Given I execute on the "<%= cb.client_pod %>" pod:
      | ping | -s 256 |-c1 | <%= cb.server_pod.ip %> |
    Then the step should fail

  # @author zzhao@redhat.com
  # @case_id OCP-22034
  @admin
  @destructive
  Scenario: Check the unused ip are released after node reboot
    Given I store the workers in the :workers clipboard
    Given I use the "<%= cb.workers[0].name %>" node
    And I run commands on the host:
      | touch /var/lib/cni/networks/openshift-sdn/10.132.2.200 &&  ls /var/lib/cni/networks/openshift-sdn/10.132.2.200 |
    Then the step should succeed
    And the output should contain "10.132.2.200"
    Given the host is rebooted and I wait it up to 600 seconds to become available
    And I run commands on the host:
      | ls /var/lib/cni/networks/openshift-sdn/ |
    Then the step should succeed
    And the output should not contain "10.132.2.200"

  # @author zzhao@redhat.com
  # @case_id OCP-41666
  # @bug_id 1924741
  @long-duration
  @admin
  @destructive
  Scenario: Pod stuck in container creating - failed to run CNI IPAM ADD: failed to allocate for range 0: no IP addresses available in range set
    Given I switch to cluster admin pseudo user
    When I run the :label admin command with:
      | resource  | machineconfigpool         |
      | name      | worker                    |
      | key_val   | custom-kubelet=large-pods |
      | overwrite | true                      |
    Then the step should succeed
    Given I obtain test data file "networking/custom_kubelet.yaml"
    When I run the :create client command with:
      | f | custom_kubelet.yaml |
    Then the step should succeed
    And I wait up to 30 seconds for the steps to pass:
    """
    When I run the :get client command with:
      | resource      | machineconfigpool |
      | resource_name | worker            |
    Then the output should match:
      | .*False\\s+True\\s+False |
    """
    And I wait up to 1980 seconds for the steps to pass:
    """
    When I run the :get client command with:
      | resource      | machineconfigpool |
      | resource_name | worker            |
    Then the output should match:
      | .*True\\s+False\\s+False |
    """
    Given admin ensures "set-max-pods" kubelet_config is deleted after scenario
    Given I store the schedulable workers in the :nodes clipboard
    Given I switch to the first user
    Given I have a project
    And evaluation of `project.name` is stored in the :proj1 clipboard
    Given I obtain test data file "networking/max-pods-without-consume-memory.yaml"
    When I run oc create over "max-pods-without-consume-memory.yaml" replacing paths:
      | ["items"][0]["spec"]["template"]["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed
    
    ##wait 700 seconds to make sure pods can consume all 509(one subnet eg 10.128.0.1/23 contains 510 ips, there is 10.128.0.1 already be used, so the rest of are 509 ips)
    And I wait up to 700 seconds for the steps to pass:
    """
    When I run command on the "<%= cb.nodes[0].name %>" node's sdn pod:
      | bash | -c | ls /host/var/lib/cni/networks/openshift-sdn \| grep "10.1" -c  |
    Then the step should succeed
    And the output should contain "509"
    """

    Given I create a new project
    Given I obtain test data file "networking/max-pods-without-consume-memory.yaml"
    When I run oc create over "max-pods-without-consume-memory.yaml" replacing paths:
      | ["items"][0]["spec"]["template"]["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed

    Given the "<%= cb.proj1 %>" project is deleted
    
    ##wait 120 seconds here to make the ip can be released
    Given 120 seconds have passed
     
    ##another project pods will continue consuming the pods ip again
    And I wait up to 700 seconds for the steps to pass:
    """
    When I run command on the "<%= cb.nodes[0].name %>" node's sdn pod:
      | bash | -c | ls /host/var/lib/cni/networks/openshift-sdn \| grep "10.1" -c  |
    Then the step should succeed
    And the output should contain "509"
    """
    When I run command on the "<%= cb.nodes[0].name %>" node's sdn pod:
      | bash | -c | ovs-vsctl --columns=external-ids,name,ofport list interface |
    Then the step should succeed
    And the output should not match "ofport.*-1"
