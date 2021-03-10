Feature: OVN related networking scenarios


  # @author anusaxen@redhat.com
  # @case_id OCP-29954
  @admin
  @destructive
  Scenario: Creating a resource in Kube API should be synced to OVN NB db correctly even post NB db crash too
    Given the env is using "OVNKubernetes" networkType
    Given I have a project
    And I obtain test data file "networking/list_for_pods.json"
    When I run the :create client command with:
      | f | list_for_pods.json |
    Then the step should succeed
    Given 2 pods become ready with labels:
      | name=test-pods |
    And evaluation of `pod(0).name` is stored in the :pod1_name clipboard
    And evaluation of `pod(1).name` is stored in the :pod2_name clipboard
    # Checking whether Kube API data is synced on OVN NB db which in this case are couple of pods
    Given I store the ovnkube-master "north" leader pod in the clipboard
    And evaluation of `pod.ip_url` is stored in the :ovn_nb_leader_ip clipboard
    And evaluation of `pod.node_name` is stored in the :ovn_nb_leader_node clipboard
    # too much output, if we don't filter server-side this always fails
    And admin executes on the pod "northd" container:
      | bash | -c | ovn-nbctl list logical_switch_port \| grep -e "<%= cb.pod1_name %>" -e "<%= cb.pod2_name %>" |
    Then the step should succeed
    And the output should contain:
      | <%= cb.pod1_name %> |
      | <%= cb.pod2_name %> |
    # Simulating a NB db crash
    Given I use the "<%= cb.ovn_nb_leader_node %>" node
    And I run commands on the host:
      | pkill -f OVN_Northbound |
    And admin waits for all pods in the "openshift-ovn-kubernetes" project to become ready up to 120 seconds
    # Making sure the pod entries are synced again when NB db is re-created
    Given I store the ovnkube-master "north" leader pod in the clipboard
    # too much output, if we don't filter server-side this always fails
    And admin executes on the pod "northd" container:
      | bash | -c | ovn-nbctl list logical_switch_port \| grep -e "<%= cb.pod1_name %>" -e "<%= cb.pod2_name %>" |
    Then the step should succeed
    And the output should contain:
      | <%= cb.pod1_name %> |
      | <%= cb.pod2_name %> |


  # @author anusaxen@redhat.com
  # @case_id OCP-30055
  @admin
  @destructive
  Scenario: OVN DB should be updated correctly if a resource only exist in Kube API but not in OVN NB db
    Given the env is using "OVNKubernetes" networkType
    Given I register clean-up steps:
    """
    And I run the :scale admin command with:
      | resource | deployment                 |
      | name     | network-operator           |
      | replicas | 1                          |
      | n        | openshift-network-operator |
    Then the step should succeed
    """
    # Now scale down CNO pod to 0
    And I run the :scale admin command with:
      | resource | deployment                 |
      | name     | network-operator           |
      | replicas | 0                          |
      | n        | openshift-network-operator |
    Then the step should succeed
    And admin ensures "ovnkube-master" ds is deleted from the "openshift-ovn-kubernetes" project
    And admin executes existing pods die with labels:
      | app=ovnkube-master |
    Given I have a project
    And I obtain test data file "networking/pod-for-ping.json"
    When I run the :create client command with:
      | f | pod-for-ping.json |
    Then the step should succeed
    # Now scale up CNO pod to 1 and check whether hello-pod is synced to NB db
    Given I run the :scale admin command with:
      | resource | deployment                 |
      | name     | network-operator           |
      | replicas | 1                          |
      | n        | openshift-network-operator |
    Then the step should succeed
    # A minimum wait for 30 seconds is tested to reflect CNO deployment to be effective which will then re-spawn ovn pods
    Given 30 seconds have passed
    # This used to be 60 seconds but around the time of 4.6 60 seconds is no longer sufficient
    And admin waits for all pods in the "openshift-ovn-kubernetes" project to become ready up to 120 seconds
    # Checking whether Kube API data is synced on OVN NB db which in this case is a test-pod created in earlier steps
    Given I store the ovnkube-master "north" leader pod in the clipboard
    # too much output, if we don't filter server-side this always fails
    And admin executes on the pod "northd" container:
      | bash | -c | ovn-nbctl list logical_switch_port \| grep hello-pod |
    Then the step should succeed
    And the output should contain:
      | hello-pod |

  # @author anusaxen@redhat.com
  # @case_id OCP-30057
  @admin
  @destructive
  Scenario: OVN DB should be updated correctly if a resource only exist in NB db but not in Kube API
    Given the env is using "OVNKubernetes" networkType
    Given I have a project
    And evaluation of `project.name` is stored in the :hello_pod_project clipboard
    And I have a pod-for-ping in the project
    # Checking whether Kube API data is synced on OVN NB db which in this case is a hello-pod created in earlier steps
    Given I store the ovnkube-master "north" leader pod in the clipboard
    # too much output, if we don't filter server-side this always fails
    And admin executes on the pod "northd" container:
      | bash | -c | ovn-nbctl list logical_switch_port \| grep hello-pod |
    Then the step should succeed
    And the output should contain:
      | hello-pod |
    # Now scale down CNO pod to 0
    Given I register clean-up steps:
    """
    And I run the :scale admin command with:
      | resource | deployment                 |
      | name     | network-operator           |
      | replicas | 1                          |
      | n        | openshift-network-operator |
    Then the step should succeed
    """
    And I run the :scale admin command with:
      | resource  | deployment                 |
      | name      | network-operator           |
      | replicas  | 0                          |
      | n         | openshift-network-operator |
    Then the step should succeed
    And admin ensures "ovnkube-master" ds is deleted from the "openshift-ovn-kubernetes" project
    And admin executes existing pods die with labels:
      | app=ovnkube-master |
    And I ensure "hello-pod" pod is deleted from the "<%= cb.hello_pod_project %>" project
    # Now scale up CNO pod to 1 and check whether hello-pod status is synced to NB db means it should not present in the DB
    Given I run the :scale admin command with:
      | namespace | openshift-network-operator |
      | resource  | deployment                 |
      | name      | network-operator           |
      | replicas  | 1                          |
      | n         | openshift-network-operator |
    Then the step should succeed
    # A recommended wait for 30 seconds is tested to reflect CNO deployment to be in effect which will then re-spawn ovn pods
    Given 30 seconds have passed
    # This used to be 60 seconds but around the time of 4.6 60 seconds is no longer sufficient
    And admin waits for all pods in the "openshift-ovn-kubernetes" project to become ready up to 120 seconds
    Given I store the ovnkube-master "north" leader pod in the clipboard
    # too much output, if we don't filter server-side this always fails
    # making sure here that hello-pod absense is properly synced
    And admin executes on the pod "northd" container:
      | bash | -c | ovn-nbctl list logical_switch_port \| grep hello-pod |
    # fail because the grep won't match anything
    Then the step should fail
    And the output should not contain:
      | hello-pod |

  # @author anusaxen@redhat.com
  # @case_id OCP-32205
  @admin
  Scenario: Thrashing ovnkube master IPAM allocator by creating and deleting various pods on a specific node
    Given the env is using "OVNKubernetes" networkType
    And I store all worker nodes to the :nodes clipboard
    And I have a project
    Given I obtain test data file "networking/generic_test_pod_with_replica.yaml"
    When I run the steps 10 times:
    """
    When I run oc create over "generic_test_pod_with_replica.yaml" replacing paths:
      | ["spec"]["replicas"]                     | 5                       |
      | ["spec"]["template"]["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed
    And 5 pods become ready with labels:
      | name=test-pods |
    Given I run the :delete client command with:
      | object_type       | rc      |
      | object_name_or_id | test-rc |
    Then the step should succeed
    And all existing pods die with labels:
      | name=test-pods |
    """

  # @author anusaxen@redhat.com
  # @case_id OCP-32184
  @admin
  Scenario: ovnkube-masters should allocate pod IP and mac addresses
    Given the env is using "OVNKubernetes" networkType
    And I have a project
    Given I have a pod-for-ping in the project
    Then evaluation of `pod.ip` is stored in the :hello_pod_ip clipboard
    When I execute on the pod:
       | bash | -c | ip a show eth0 |
    Then the step should succeed
    And evaluation of `@result[:response].match(/\h+:\h+:\h+:\h+:\h+:\h+/)[0]` is stored in the :hello_pod_mac clipboard

    Given I store the ovnkube-master "north" leader pod in the clipboard
    And admin executes on the pod:
      | bash | -c | ovn-nbctl list logical_switch_port \| grep "hello-pod" -C 10 |
    Then the step should succeed
    # Make sure addresses don't say dynamic but display ip and mac assigned to the hello-pod and dynamic_addresses field should be empty
    And the output should contain:
      | addresses           : ["<%= cb.hello_pod_mac %> <%= cb.hello_pod_ip %>"] |
      | dynamic_addresses   : []                                                 |

  # @author rbrattai@redhat.com
  # @case_id OCP-28936
  @admin
  @destructive
  Scenario: Create/delete pods while forcing OVN leader election
  #Test for bug https://bugzilla.redhat.com/show_bug.cgi?id=1781297
    Given the env is using "OVNKubernetes" networkType
    Given I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard

    Given I run the steps 4 times:
    """
    Given I have a pod-for-ping in the "<%= cb.usr_project %>" project
    Given I store the ovnkube-master "south" leader pod in the clipboard
    When admin deletes the ovnkube-master "south" leader
    Then the step should succeed
    When I store the ovnkube-master "south" leader pod in the :new_south_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.south_leader.name != cb.new_south_leader.name
    And admin waits for all pods in the "openshift-ovn-kubernetes" project to become ready up to 120 seconds
    Given I ensure "hello-pod" pod is deleted from the "<%= cb.usr_project%>" project
    """


  # @author rbrattai@redhat.com
  # @case_id OCP-26092
  @admin
  @destructive
  Scenario: Pods and Services should keep running when a new raft leader gets be elected
    Given the env is using "OVNKubernetes" networkType
    Given I store the ovnkube-master "south" leader pod in the clipboard
    Given I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/list_for_pods.json"
    When I run the :create client command with:
      | f | list_for_pods.json |
    Then the step should succeed
    Given 2 pods become ready with labels:
      | name=test-pods |
    And I store in the :test_pods clipboard the pods labeled:
      | name=test-pods |

    # Check pod works
    When I execute on the "<%= cb.test_pods[1].name %>" pod:
      | curl | -s | --connect-timeout | 60 | <%= cb.test_pods[0].ip_url %>:8080 |
    Then the step should succeed
    And the output should contain "Hello OpenShift"

    When admin deletes the ovnkube-master "south" leader
    Then the step should succeed

    When I store the ovnkube-master "south" leader pod in the :new_south_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.south_leader.name != cb.new_south_leader.name
    And admin waits for all pods in the "openshift-ovn-kubernetes" project to become ready up to 120 seconds

    # Check pod works
    Given I use the "<%= cb.usr_project%>" project
    When I execute on the "<%= cb.test_pods[1].name %>" pod:
      | curl | -s | --connect-timeout | 60 | <%= cb.test_pods[0].ip_url %>:8080 |
    Then the step should succeed
    And the output should contain "Hello OpenShift"


  # @author rbrattai@redhat.com
  # @case_id OCP-26139
  @admin
  @destructive
  Scenario: Traffic flow shouldn't be interrupted when master switches the leader positions
    Given the env is using "OVNKubernetes" networkType
    Given I switch to cluster admin pseudo user
    Given admin creates a project
    And evaluation of `project.name` is stored in the :iperf_project clipboard
    And admin uses the "<%= cb.iperf_project %>" project

    Given I obtain test data file "networking/iperf_nodeport_service.json"
    When I run the :create admin command with:
      | f | iperf_nodeport_service.json |
    Then the step should succeed
    And the pod named "iperf-server" becomes ready
    # readiness probe won't work because iperf-client will fail, we just have to wait for server to
    # become extra ready?
    Given 10 seconds have passed

    Given I store the ovnkube-master "south" leader pod in the clipboard
    Given I store the masters in the :masters clipboard

    # place directly on master
    Given I obtain test data file "networking/egress-ingress/qos/iperf-server.json"
    When I run oc create as admin over "iperf-server.json" replacing paths:
      | ["spec"]["containers"][0]["args"] | ["-c", "<%= service("iperf-server").ip %>", "-u", "-J", "-t", "30"] |
      | ["spec"]["containers"][0]["name"] | "iperf-client"                                                      |
      | ["metadata"]["name"]              | "iperf-client"                                                      |
      | ["spec"]["nodeName"]              | "<%= cb.masters[0].name %>"                                         |
      | ["spec"]["hostNetwork"]           | true                                                                |
      | ["spec"]["restartPolicy"]         | "Never"                                                             |
    Then the step should succeed
    And the pod named "iperf-client" becomes ready

    When admin deletes the ovnkube-master "south" leader
    Then the step should succeed
    When I store the ovnkube-master "south" leader pod in the :new_south_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.south_leader.name != cb.new_south_leader.name
    # one instance took 55 seconds for the first pod and then timed out, so wait a while
    And admin waits for all pods in the "openshift-ovn-kubernetes" project to become ready up to 120 seconds
    Given I use the "<%= cb.iperf_project %>" project
    When the pod named "iperf-client" status becomes :succeeded within 120 seconds
    And I run the :logs client command with:
      | resource_name | iperf-client |
    Then the step should succeed
    And the output is parsed as JSON
    Then the expression should be true> @result[:parsed]['end']['sum']['lost_percent'].to_f < 10
    Then the expression should be true> @result[:parsed]['end']['sum']['bytes'].to_f > 1024
    Then the expression should be true> @result[:parsed]['end']['sum']['packets'].to_f > 0
    Then the expression should be true> @result[:parsed]['end']['sum']['jitter_ms'].to_f < 1
    And I run the :logs client command with:
      | resource_name | iperf-server |
    Then the step should succeed
    And the output is parsed as JSON
    Then the expression should be true> @result[:parsed]['end']['sum']['lost_percent'].to_f < 10
    # server doesn't count bytes
    Then the expression should be true> @result[:parsed]['end']['sum']['packets'].to_f > 0
    # try < 5 ms jitter, really anything < 20 ms might be considered good.
    Then the expression should be true> @result[:parsed]['end']['sum']['jitter_ms'].to_f < 5


  # @author rbrattai@redhat.com
  # @case_id OCP-26089
  @admin
  @destructive
  Scenario: New raft leader should be elected if existing leader gets deleted or crashed in hybrid/non-hybrid clusters
    Given the env is using "OVNKubernetes" networkType
    Given admin uses the "openshift-ovn-kubernetes" project
    When I store the ovnkube-master "north" leader pod in the clipboard
    Then the step should succeed
    Given admin ensures "<%= cb.north_leader.name %>" pod is deleted from the "openshift-ovn-kubernetes" project
    Then the step should succeed
    And I wait up to 30 seconds for the steps to pass:
    """
    When I store the ovnkube-master "north" leader pod in the :new_north_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.north_leader.name != cb.new_north_leader.name
    """
    And admin waits for all pods in the project to become ready up to 120 seconds


  # @author rbrattai@redhat.com
  # @case_id OCP-26091
  @admin
  @destructive
  Scenario: New corresponding raft leader should be elected if SB db or NB db on existing master is crashed
    Given the env is using "OVNKubernetes" networkType
    Given admin uses the "openshift-ovn-kubernetes" project
    When I store the ovnkube-master "south" leader pod in the clipboard
    Then the step should succeed
    When the OVN "south" database is killed on the "<%= cb.south_leader.node_name %>" node
    Then the step should succeed

    And I wait up to 30 seconds for the steps to pass:
    """
    When I store the ovnkube-master "south" leader pod in the :new_south_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.south_leader.name != cb.new_south_leader.name
    """
    And admin waits for all pods in the project to become ready up to 120 seconds

    When I store the ovnkube-master "north" leader pod in the clipboard
    Then the step should succeed
    When the OVN "north" database is killed on the "<%= cb.north_leader.node_name %>" node
    Then the step should succeed

    And I wait up to 30 seconds for the steps to pass:
    """
    When I store the ovnkube-master "north" leader pod in the :new_north_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.north_leader.name != cb.new_north_leader.name
    """
    And admin waits for all pods in the project to become ready up to 120 seconds


  # @author rbrattai@redhat.com
  # @case_id OCP-26138
  @admin
  @destructive
  Scenario: Inducing Split Brain in the OVN HA cluster
    Given admin uses the "openshift-ovn-kubernetes" project
    When I store the ovnkube-master "south" leader pod in the clipboard
    Then the step should succeed

    Given I store the masters in the clipboard excluding "<%= cb.south_leader.node_name %>"
    And I use the "<%= cb.nodes[0].name %>" node
    # make sure to unblock after the test
    And I register clean-up steps:
    """
    When I run commands on the host:
      | iptables -t filter -D INPUT -s <%= cb.south_leader.ip %> -p tcp --dport 9643:9644 -j DROP |
    """
    # don't block all traffic that breaks etcd, just block the OVN ssl ports
    When I run commands on the host:
      | iptables -t filter -A INPUT -s <%= cb.south_leader.ip %> -p tcp --dport 9643:9644 -j DROP |
    Then the step should succeed

    # election timer is 1 second by default but the RAFT JSON-RPC probe might take 5 seconds to notice
    And I wait up to 40 seconds for the steps to pass:
    # check the leader on the original leader to ensure it is still the leader and the split node doesn't become leader
    """
    When I store the ovnkube-master "south" leader pod in the :original_south_leader clipboard using node "<%= cb.south_leader.node_name %>"
    Then the step should succeed
    When I store the ovnkube-master "south" leader pod in the :isolated_south_leader clipboard using node "<%= cb.nodes[0].name %>"
    Then the step should succeed
    """
    # try to get the isolated leader for debug, it might not work
    When I run commands on the host:
      | iptables -t filter -D INPUT -s <%= cb.south_leader.ip %> -p tcp --dport 9643:9644 -j DROP |
    # wait for OVN to reconverge
    # election timer is 1 second by default but the RAFT JSON-RPC probe might take 5 seconds to notice
    And I wait up to 40 seconds for the steps to pass:
    # check the leader on the original leader to ensure it is still the leader and the split node doesn't become leader
    """
    When I store the ovnkube-master "south" leader pod in the :after_south_leader clipboard using node "<%= cb.south_leader.node_name %>"
    Then the step should succeed
    When I store the ovnkube-master "south" leader pod in the :after_isolated_south_leader clipboard using node "<%= cb.nodes[0].name %>"
    Then the step should succeed
    """
    And admin waits for all pods in the project to become ready up to 120 seconds


  # @author rbrattai@redhat.com
  # @case_id OCP-26140
  @admin
  @destructive
  Scenario: Delete all OVN master pods and makes sure leader/follower election converges smoothly
    Given the env is using "OVNKubernetes" networkType
    Given admin uses the "openshift-ovn-kubernetes" project
    When I store the ovnkube-master "north" leader pod in the clipboard
    Then the step should succeed
    When I run the :delete admin command with:
      | object_type | pod                |
      | l           | app=ovnkube-master |
    Then the step should succeed
    And I wait up to 30 seconds for the steps to pass:
    """
    When I store the ovnkube-master "north" leader pod in the :new_north_leader clipboard
    Then the step should succeed
    And the expression should be true> cb.north_leader.name != cb.new_north_leader.name
    """
    And admin waits for all pods in the project to become ready up to 120 seconds


  # @author rbrattai@redhat.com
  # @case_id OCP-37031
  @admin
  Scenario: OVN handles projects that start with a digit
    Given the env is using "OVNKubernetes" networkType
    Given I create a project with leading digit name
    And I obtain test data file "networking/list_for_pods.json"
    When I run the :create client command with:
      | f | list_for_pods.json |
    Then the step should succeed
    Given 2 pods become ready with labels:
      | name=test-pods |
    When I run command on the "<%= pod(0).node_name %>" node's sdn pod:
      | bash | -c | ovs-vsctl list interface \| grep iface-id |
    Then the step should succeed
    # the iface-id should be quoted if it starts with a digit
    And the output should contain "<%= project.name %>"


  # @author huirwang@redhat.com
  # @case_id OCP-38132
  @admin
  @destructive
  Scenario: Should no intermittent packet drop from pod to pod after change hostname
    Given I store the schedulable workers in the :nodes clipboard
    Given admin uses the "openshift-ovn-kubernetes" project
    And I store the hostname from external ids in the :original_hostname clipboard on the "<%= cb.nodes[0].name %>" node
    Then the step should succeed
    And I store the "short" hostname in the :short_hostname clipboard for the "<%= cb.nodes[0].name %>" node
    Then the step should succeed

    # Configure short hostname to the external_ids for the ovn node
    When I set "<%= cb.short_hostname %>" hostname to external ids on the "<%= cb.nodes[0].name %>" node
    Then the step should succeed
    Given I register clean-up steps:
    """
    When I set "<%= cb.original_hostname%>" hostname to external ids on the "<%= cb.nodes[0].name %>" node
    Then the step should succeed
    """

    # Check short hostname was set
    Given I store the ovnkube-master "north" leader pod in the clipboard
    Given I wait up to 15 seconds for the steps to pass:
    """
    And admin executes on the pod "northd" container:
      | bash | -c | ovn-sbctl --no-leader-only list chassis \|grep "<%= cb.short_hostname %>" |
    Then the step should succeed
    And the output should contain:
      | <%= cb.short_hostname %> |
    And the output should not contain:
      | <%= cb.original_hostname%> |
    """

    #Check no packet drop from pod to pod
    Given I have a project
    And I obtain test data file "networking/aosqe-pod-for-ping.json"
    When I run oc create over "aosqe-pod-for-ping.json" replacing paths:
      | ["spec"]["nodeName"] | <%= cb.nodes[0].name %> |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=hello-pod |
    And evaluation of `pod(1).name` is stored in the :pod1_name clipboard
    Given I obtain test data file "networking/list_for_pods.json"
    When I run oc create over "list_for_pods.json" replacing paths:
      | ["items"][0]["spec"]["nodeName"] | <%= cb.nodes[1].name %> |
      | ["items"][0]["spec"]["replicas"] | 1                       |
    Then the step should succeed
    Given 1 pod becomes ready with labels:
      | name=test-pods |
    And evaluation of `pod(2).ip` is stored in the :pod2_ip clipboard

    When I execute on the "<%= cb.pod1_name%>" pod:
      | ping | -c | 30 | -i | 0.2 | <%= cb.pod2_ip%> |
    Then the step should succeed
    And the output should contain "0% packet loss"
