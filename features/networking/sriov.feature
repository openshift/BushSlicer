Feature: Sriov related scenarios

  # @author zzhao@redhat.com
  # @case_id OCP-29944
  @admin
  Scenario: sriov operator can be setup and running well
    Given I switch to cluster admin pseudo user
    And I use the "openshift-sriov-network-operator" project
    And all existing pods are ready with labels:
      | app=network-resources-injector  |
    And all existing pods are ready with labels:
      | app=operator-webhook            |
    And all existing pods are ready with labels:
      | app=sriov-network-config-daemon |
    And status becomes :running of exactly 1 pods labeled:
      | name=sriov-network-operator     |


  # @author zzhao@redhat.com
  # @case_id OCP-24702
  @destructive
  @admin
  Scenario: netdevice VF for XXV710 can be worked well when sriovnetworknodepolicies is created for rhcos node
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/intel-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intel-netdevice.yaml     |
      | cr_name       | intel-netdevice          |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 300 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | intel-netdevice       |
      | syncStatus: Succeeded |
      | vfID: 4               |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/static-sriovnetwork.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | static-sriovnetwork.yaml |
      | cr_name       | static-sriovnetwork      |
      | resource_type | sriovnetwork             |
      | project       | <%= cb.usr_project%>     |
    Then the step should succeed

    And admin checks that the "static-sriovnetwork" network_attachment_definition exists in the "<%= cb.usr_project%>" project
    Given I switch to the first user
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-without-resource-static.yaml"
    When I run the :create client command with:
      | f | sriov-without-resource-static.yaml |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-static |
    When I execute on the pod:
      | bash | -c | ip addr show net1 |
    Then the output should contain:
      | 192.168.2.206 |
      | 2001::2/64    |

  # @author zzhao@redhat.com
  # @case_id OCP-21364
  @destructive
  @admin
  Scenario: Create pod with sriov-cni plugin and macvlan on the same interface
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/intel-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intel-netdevice.yaml     |
      | cr_name       | intel-netdevice          |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 300 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | intel-netdevice       |
      | syncStatus: Succeeded |
      | vfID: 4               |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/intelnetdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intelnetdevice.yaml   |
      | cr_name       | intel-netdevice-rhcos |
      | resource_type | sriovnetwork          |
      | project       | <%= cb.usr_project%>  |
    Then the step should succeed

    And admin checks that the "intel-netdevice-rhcos" network_attachment_definition exists in the "<%= cb.usr_project%>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/multus-cni/NetworkAttachmentDefinitions/macvlan-conf-without-master.yaml"
    When I run the :create admin command with:
      | f         | macvlan-conf-without-master.yaml |
      | namespace | <%= cb.usr_project %>            |
    Then the step should succeed
    Given I obtain test data file "networking/sriov/pod/sriov-macvlan.yaml"
    When I run the :create client command with:
      | f | sriov-macvlan.yaml |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-macvlan |
    When I execute on the pod:
      | ip | -d | link |
    Then the output should contain:
      | net1 |
      | net2 |
    When I execute on the pod:
      | bash | -c | ip addr show net1 |
    Then the output should contain "10.56.217"
    When I execute on the pod:
      | bash | -c | ip addr show net2 |
    Then the output should contain "192.168.1"

  # @author zzhao@redhat.com
  # @case_id OCP-24713
  @destructive
  @admin
  Scenario: NAD can be also updated when networknamespace is change
    Given the sriov operator is running well
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project1 clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/intelnetdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intelnetdevice.yaml   |
      | cr_name       | intel-netdevice-rhcos |
      | resource_type | sriovnetwork          |
      | project       | <%= cb.usr_project1%> |
    Then the step should succeed

    And admin checks that the "intel-netdevice-rhcos" network_attachment_definition exists in the "<%= cb.usr_project1%>" project
    Given I switch to the first user
    Given I create a new project
    And evaluation of `project.name` is stored in the :usr_project2 clipboard
    When I run the :patch admin command with:
      | resource      | sriovnetworks.sriovnetwork.openshift.io               |
      | resource_name | intel-netdevice-rhcos                                 |
      | p             | {"spec":{"networkNamespace":"<%= cb.usr_project2%>"}} |
      | type          | merge                                                 |
    Then the step should succeed
    And admin checks that there are no network_attachment_definition in the "<%= cb.usr_project1%>" project
    And admin checks that the "intel-netdevice-rhcos" network_attachment_definition exists in the "<%= cb.usr_project2 %>" project

  # @author zzhao@redhat.com
  @destructive
  @admin
  Scenario Outline: VF can be worked well when sriovnetworknodepolicies is created for rhcos node
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/<cardname>-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | <cardname>-netdevice.yaml    |
      | cr_name       | <cardname>-netdevice         |
      | resource_type | sriovnetworknodepolicies     |
    Then the step should succeed
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | <cardname>-netdevice  |
      | syncStatus: Succeeded |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/<cardname>netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | <cardname>netdevice.yaml |
      | cr_name       | <cardname>-netdevice     |
      | resource_type | sriovnetwork             |
      | project       | <%= cb.usr_project%>     |
    Then the step should succeed

    And admin checks that the "<cardname>-netdevice" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-macvlan.yaml"
    When I run oc create over "sriov-macvlan.yaml" replacing paths:
      | ["metadata"]["annotations"]["k8s.v1.cni.cncf.io/networks"] | <cardname>-netdevice |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-macvlan |
    When I execute on the pod:
      | ip | a |
    Then the output should contain:
      | 10.56.217 |

    Examples:
      | cardname |
      | mlx277   | # @case_id OCP-24774
      | mlx278   | # @case_id OCP-24775

  # @author zzhao@redhat.com
  # @case_id OCP-24780
  @destructive
  @admin
  Scenario: NAD will be deleted too when sriovnetwork is deleted
    Given the sriov operator is running well
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project1 clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/intelnetdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intelnetdevice.yaml   |
      | cr_name       | intel-netdevice-rhcos |
      | resource_type | sriovnetwork          |
      | project       | <%= cb.usr_project1%> |
    Then the step should succeed

    And admin checks that the "intel-netdevice-rhcos" network_attachment_definition exists in the "<%= cb.usr_project1 %>" project
    And admin checks that the "intel-netdevice-rhcos" sriov_network is deleted from the "openshift-sriov-network-operator" project 
    And admin checks that there are no network_attachment_definition in the "<%= cb.usr_project1 %>" project

  # @author zzhao@redhat.com
  # @case_id OCP-25287
  @destructive
  @admin
  Scenario: NAD should be able to restore by sriov operator when it was deleted
    Given the sriov operator is running well
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/intelnetdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intelnetdevice.yaml   |
      | cr_name       | intel-netdevice-rhcos |
      | resource_type | sriovnetwork          |
      | project       | <%= cb.usr_project%>  |
    Then the step should succeed

    And admin checks that the "intel-netdevice-rhcos" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    When I run the :delete admin command with:
      | object_type       | net-attach-def        |
      | object_name_or_id | intel-netdevice-rhcos |
      | namespace         | <%= cb.usr_project1%> |
    Then the step should succeed
    And I wait up to 30 seconds for the steps to pass:
    """
    And admin checks that the "intel-netdevice-rhcos" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    """

  # @author zzhao@redhat.com
  # @case_id OCP-25790
  @admin
  @destructive
  Scenario: SR-IOV network config daemon can be set by nodeselector
    Given the sriov operator is running well
    And all existing pods are ready with labels:
      | app=sriov-network-config-daemon |
    Given configDaemonNodeSelector set to false in sriovoperatorconfig
    And I wait for the resource "pod" named "<%= pod.name %>" to disappear within 120 seconds
    Given configDaemonNodeSelector set to true in sriovoperatorconfig
    Then all existing pods are ready with labels:
      | app=sriov-network-config-daemon |

  # @author zzhao@redhat.com
  # @case_id OCP-26134
  @destructive
  @admin
  Scenario: sriov can be shown in Metrics and telemetry
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/mlx278-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278-netdevice.yaml    |
      | cr_name       | mlx278-netdevice         |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | mlx278-netdevice      |
      | syncStatus: Succeeded |
      | vfID: 0               |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/mlx278netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278netdevice.yaml |
      | cr_name       | mlx278-netdevice     |
      | resource_type | sriovnetwork         |
      | project       | <%= cb.usr_project%> |
    Then the step should succeed

    And admin checks that the "mlx278-netdevice" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-macvlan.yaml"
    When I run oc create over "sriov-macvlan.yaml" replacing paths:
      | ["metadata"]["annotations"]["k8s.v1.cni.cncf.io/networks"] | mlx278-netdevice |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-macvlan |
    And evaluation of `pod.name` is stored in the :pod_name clipboard

    Given I switch to cluster admin pseudo user
    Given admin uses the "openshift-multus" project
    When evaluation of `endpoints('multus-admission-controller').subsets.first.addresses.first.ip.to_s` is stored in the :mac_ip clipboard
    Given admin uses the "openshift-monitoring" project
    When evaluation of `secret(service_account('prometheus-k8s').get_secret_names.find {|s| s.match('token')}).token` is stored in the :sa_token clipboard

    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://<%= cb.mac_ip %>:8443/metrics |
    Then the step should succeed
    And the output should contain:
      | network_attachment_definition_enabled_instance_up{networks="any"} 1   |
      | network_attachment_definition_enabled_instance_up{networks="sriov"} 1 |
      | network_attachment_definition_instances{networks="any"} 1             |
      | network_attachment_definition_instances{networks="sriov"} 1           |

    Given I switch to the first user
    Given I ensure "<%= cb.pod_name%>" pod is deleted from the "<%= cb.usr_project%>" project

    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://<%= cb.mac_ip %>:8443/metrics |
    Then the step should succeed
    And the output should contain:
      | network_attachment_definition_enabled_instance_up{networks="any"} 0   |
      | network_attachment_definition_enabled_instance_up{networks="sriov"} 0 |
      | network_attachment_definition_instances{networks="any"} 0             |
      | network_attachment_definition_instances{networks="sriov"} 0           |


  # @author zzhao@redhat.com
  # @case_id OCP-33454
  @destructive
  @admin
  Scenario: VF mac can be set with container mac address
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/mlx278-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278-netdevice.yaml    |
      | cr_name       | mlx278-netdevice         |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | mlx278-netdevice      |
      | syncStatus: Succeeded |
      | vfID: 0               |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/mlx278netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278netdevice.yaml |
      | cr_name       | mlx278-netdevice     |
      | resource_type | sriovnetwork         |
      | project       | <%= cb.usr_project%> |
    Then the step should succeed

    And admin checks that the "mlx278-netdevice" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-macvlan.yaml"
    When I run oc create over "sriov-macvlan.yaml" replacing paths:
      | ["metadata"]["annotations"]["k8s.v1.cni.cncf.io/networks"] | mlx278-netdevice |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-macvlan |
    When I execute on the pod:
      | bash | -c | cat /sys/class/net/net1/address |
    Then the step should succeed
    And evaluation of `@result[:response].strip` is stored in the :pod1_net1_mac clipboard
    Given I use the "<%= pod.node_name %>" node
    And I run commands on the host:
      | ip link show ens3f0 |
    Then the step should succeed
    And the output should contain "<%= cb.pod1_net1_mac %>"


  # @author zzhao@redhat.com
  @destructive
  @admin
  Scenario Outline: SR-IOV resource can be disable by edit SR-IOV Operator Config
    Given the sriov operator is running well
    Given <sriov-feature> is disabled
    #check the related resource should be removed
    And I wait up to 30 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | ds |
    Then the step should succeed
    And the output should not contain "<keyword>"
    When I run the :get admin command with:
      | resource    | sa |
    Then the step should succeed
    And the output should not contain "<keyword>"
    When I run the :get admin command with:
      | resource    | svc |
    Then the step should succeed
    And the output should not contain "<keyword>"
    When I run the :get admin command with:
      | resource    | clusterrole |
    Then the step should succeed
    And the output should not contain "<keyword>"
    When I run the :get admin command with:
      | resource    | MutatingWebhookConfiguration |
    Then the step should succeed
    And the output should not contain "<keyword>"
    When I run the :get admin command with:
      | resource    | cm |
    Then the step should succeed
    And the output should not contain "<keyword>"
    When I run the :get admin command with:
      | resource    | clusterrolebinding |
    Then the step should succeed
    And the output should not contain "<keyword>"
    """

    Examples:
      | sriov-feature             | keyword           |
      | SR-IOV resource injector  | injector          |  # @case_id OCP-25814
      | Admission webhook         | operator-webhook  |  # @case_id OCP-25847

  # @author zzhao@redhat.com
  # @case_id OCP-25835
  @destructive
  @admin
  Scenario: SR-IOV resource injector should not overwrite the request memory and cpu
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/mlx278-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278-netdevice.yaml    |
      | cr_name       | mlx278-netdevice         |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | mlx278-netdevice      |
      | syncStatus: Succeeded |
      | vfID: 0               |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/mlx278netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278netdevice.yaml |
      | cr_name       | mlx278-netdevice     |
      | resource_type | sriovnetwork         |
      | project       | <%= cb.usr_project%> |
    Then the step should succeed

    And admin checks that the "mlx278-netdevice" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-specified-cpu.yaml"
    When I run the :create client command with:
      | f | sriov-specified-cpu.yaml |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-specified-cpu |
    Given I get project pod named "<%= pod.name %>" as YAML
    And the output should contain:
      | cpu: 333    |
      | memory: 345 |

  # @author zzhao@redhat.com
  # @case_id OCP-25844
  @destructive
  @admin
  Scenario Outline: Admission webhook can validate the data of sriovnetworknodepolicies
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/wrong/<file>"
    When I run the :create client command with:
      | f | <file> |
    Then the step should fail
    And the output should contain "<Error message>"

    Examples:
      | file              | Error message                |
      | invalidname.yaml  | invalid characters           |
      | non-deviceid      | no supported NIC             |
      | non-vondor        | vendor 15b4 is not supported |
      | vfnum0            | numVfs(0) in CR              |


  # @author zzhao@redhat.com
  # @case_id OCP-28076
  @destructive
  @admin
  Scenario: vf range should be correct if create sriovnetworkpolicy without pfNames
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/intel-netdevice-without-pf.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | intel-netdevice-without-pf.yaml |
      | cr_name       | intel-netdevice                 |
      | resource_type | sriovnetworknodepolicies        |
    Then the step should succeed
    And I wait up to 300 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | intel-netdevice       |
      | syncStatus: Succeeded |
      | vfID: 4               |
    """
    When I run the :get admin command with:
      | resource      | node                                          |
      | l             | feature.node.kubernetes.io/sriov-capable=true |
      | o             | yaml                                          |
    Then the step should succeed
    And the output should contain "openshift.io/intelnetdevice: "5""

  # @author zzhao@redhat.com
  # @case_id OCP-30268
  @destructive
  @admin
  Scenario: user can set the loglevel for sriov config daemon
    Given the sriov operator is running well
    Given sriov config daemon is ready
    Given I patch the sriov logs to "0"
    Then the step should succeed
    Given 10 seconds have passed
    When I run the :logs admin command with:
      | resource_name | <%= pod.name %> |
      | since         | 10s             |
    Then the step should succeed
    And the output should not contain "nodeUpdateHandler"
    Given I patch the sriov logs to "2"
    Then the step should succeed
    Given 10 seconds have passed
    When I run the :logs admin command with:
      | resource_name | <%= pod.name %> |
      | since         | 10s             |
    Then the step should succeed
    And the output should contain "nodeUpdateHandler"

  # @author zzhao@redhat.com
  # @case_id OCP-30269
  @destructive
  @admin
  Scenario: Negtive testing for loglevel for sriov config daemon
    Given the sriov operator is running well
    Given sriov config daemon is ready
    Given I patch the sriov logs to "3"
    Then the step should fail
    And the output should contain "logLevel in body should be less than or equal to 2"
    Given I patch the sriov logs to "-1"
    Then the step should fail
    And the output should contain "logLevel in body should be greater than or equal to 0"

  # @author zzhao@redhat.com
  # @case_id OCP-30277
  @destructive
  @admin
  Scenario: Loglevel value should be explain in CRD
    Given the sriov operator is running well
    When I run the :explain client command with:
      | resource | sriovoperatorconfigs.spec.logLevel |
    Then the step should succeed
    And the output should contain "Flag to control the log verbose level of the operator"

  # @author zzhao@redhat.com
  # @case_id OCP-32642
  @destructive
  @admin
  Scenario: MTU can be set according to policy is specified
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/mlx278-netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278-netdevice.yaml    |
      | cr_name       | mlx278-netdevice         |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | mlx278-netdevice      |
      | syncStatus: Succeeded |
      | mtu: 1800             |
      | vfID: 0               |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/mlx278netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx278netdevice.yaml |
      | cr_name       | mlx278-netdevice     |
      | resource_type | sriovnetwork         |
      | project       | <%= cb.usr_project%> |
    Then the step should succeed

    And admin checks that the "mlx278-netdevice" network_attachment_definition exists in the "<%= cb.usr_project%>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-macvlan.yaml"
    When I run oc create over "sriov-macvlan.yaml" replacing paths:
      | ["metadata"]["annotations"]["k8s.v1.cni.cncf.io/networks"] | mlx278-netdevice |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-macvlan |
    When I execute on the pod:
      | bash | -c | ip a show net1 |
    Then the step should succeed
    And the output should contain "mtu 1800"
    And evaluation of `pod.node_name` is stored in the :pod_node clipboard
    #Delete the networkpolicy, the PF Mtu should rollback to origin value.
    Given admin ensures "mlx278-netdevice" sriov_network_node_policy is deleted from the "openshift-sriov-network-operator" project
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should not contain:
      | ens3f0v0              |
      | mlx278-netdevice      |
      | syncStatus: Succeeded |
    """
    Given I use the "<%= cb.pod_node %>" node
    And I run commands on the host:
      | ip link show ens3f0 |
    Then the step should succeed
    And the output should contain "mtu 1800"

  # @author zzhao@redhat.com
  # @case_id OCP-32641
  @destructive
  @admin
  Scenario: MTU can be set according the PF when policy is not specified
    Given the sriov operator is running well
    Given sriov config daemon is ready
    And I use the "<%= pod.node_name %>" node
    And I run commands on the host:
      | ip link set dev ens2f0 mtu 2020 |
    Then the step should succeed
    Given I obtain test data file "networking/sriov/sriovnetworkpolicy/mlx277-netdevice-without-mtu.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx277-netdevice-without-mtu.yaml    |
      | cr_name       | mlx277-netdevice-without-mtu         |
      | resource_type | sriovnetworknodepolicies             |
    Then the step should succeed
    And I wait up to 500 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | mlx277-netdevice-without-mtu |
      | syncStatus: Succeeded        |
      | vfID: 1                      |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/sriovnetwork/mlx277netdevice.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | mlx277netdevice.yaml |
      | cr_name       | mlx277-netdevice     |
      | resource_type | sriovnetwork         |
      | project       | <%= cb.usr_project%> |
    Then the step should succeed

    And admin checks that the "mlx277-netdevice" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/pod/sriov-macvlan.yaml"
    When I run oc create over "sriov-macvlan.yaml" replacing paths:
      | ["metadata"]["annotations"]["k8s.v1.cni.cncf.io/networks"] | mlx277-netdevice |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=sriov-macvlan |
    When I execute on the pod:
      | bash | -c | ip a show net1 |
    Then the step should succeed
    And the output should contain "mtu 2020"

  # @author zzhao@redhat.com
  # @case_id OCP-34092
  @destructive
  @admin
  Scenario: sriov-device-plugin can be scheduled on any node
    Given the sriov operator is running well
    When I run the :get admin command with:
      | resource  | ds/sriov-device-plugin            |
      | namespace | openshift-sriov-network-operator  |
      | o         | yaml                              |
    Then the step should succeed
    And the output should contain "operator: Exists"
    And the output should not contain "NoSchedule"
