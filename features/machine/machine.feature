Feature: Machine features testing

  # @author jhou@redhat.com
  # @case_id OCP-21196
  @smoke
  Scenario: Machines should be linked to nodes
    Given I have an IPI deployment
    Then the machines should be linked to nodes

  # @author jhou@redhat.com
  # @case_id OCP-22115
  @smoke
  @admin
  Scenario: machine-api clusteroperator should be in Available state
    Given evaluation of `cluster_operator('machine-api').condition(type: 'Available')` is stored in the :co_available clipboard
    Then the expression should be true> cb.co_available["status"]=="True"

    Given evaluation of `cluster_operator('machine-api').condition(type: 'Degraded')` is stored in the :co_degraded clipboard
    Then the expression should be true> cb.co_degraded["status"]=="False"

    Given evaluation of `cluster_operator('machine-api').condition(type: 'Upgradeable')` is stored in the :co_upgradable clipboard
    Then the expression should be true> cb.co_upgradable["status"]=="True"

    Given evaluation of `cluster_operator('machine-api').condition(type: 'Progressing')` is stored in the :co_progressing clipboard
    Then the expression should be true> cb.co_progressing["status"]=="False"

  # @author zhsun@redhat.com
  # @case_id OCP-37706
  @smoke
  @admin
  Scenario: Baremetal clusteroperator should be disabled in any deployment that is not baremetal
    Given evaluation of `cluster_operator('baremetal').condition(type: 'Disabled')` is stored in the :co_disabled clipboard
    Then the expression should be true> cb.co_disabled["status"]=="True"

  # @author jhou@redhat.com
  # @case_id OCP-25436
  @admin
  @destructive
  Scenario: Scale up and scale down a machineSet
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    And admin ensures machine number is restored after scenario

    Given I clone a machineset and name it "machineset-clone-25436"

    Given I scale the machineset to +2
    Then the step should succeed
    And the machineset should have expected number of running machines

    When I scale the machineset to -1
    Then the step should succeed
    And the machineset should have expected number of running machines


  # @author jhou@redhat.com
  @admin
  Scenario Outline: Metrics is exposed on https
    Given I switch to cluster admin pseudo user
    And I use the "openshift-monitoring" project
    And evaluation of `secret(service_account('prometheus-k8s').get_secret_names.find {|s| s.match('token')}).token` is stored in the :token clipboard

    When I run the :exec admin command with:
      | n                | openshift-monitoring                                           |
      | pod              | prometheus-k8s-0                                               |
      | c                | prometheus                                                     |
      | oc_opts_end      |                                                                |
      | exec_command     | sh                                                             |
      | exec_command_arg | -c                                                             |
      | exec_command_arg | curl -v -s -k -H "Authorization: Bearer <%= cb.token %>" <url> |
    Then the step should succeed

    Examples:
      | url                                                                          |
      | https://machine-api-operator.openshift-machine-api.svc:8443/metrics          | # @case_id OCP-25652
      | https://cluster-autoscaler-operator.openshift-machine-api.svc:9192/metrics   | # @case_id OCP-26111
      | https://machine-approver.openshift-cluster-machine-approver.svc:9192/metrics | # @case_id OCP-26102

  # @author zhsun@redhat.com
  # @case_id OCP-25608
  @admin
  @destructive
  Scenario: Machine should have immutable field providerID and nodeRef
    Given I have an IPI deployment
    Given I store the last provisioned machine in the :machine clipboard
    And evaluation of `machine(cb.machine).node_name` is stored in the :nodeRef_name clipboard
    And evaluation of `machine(cb.machine).provider_id` is stored in the :providerID clipboard

    When I run the :patch admin command with:
      | resource      | machine                                |
      | resource_name | <%= cb.machine %>                      |
      | p             | {"status":{"nodeRef":{"name":"test"}}} |
      | type          | merge                                  |
      | n             | openshift-machine-api                  |
    Then the step should succeed
    When I run the :describe admin command with:
      | resource      | machine                                |
      | name          | <%= cb.machine %>                      |
      | n             | openshift-machine-api                  |
    Then the step should succeed
    And the output should match "Name:\s+<%= cb.nodeRef_name %>"

    When I run the :patch admin command with:
      | resource      | machine                                |
      | resource_name | <%= cb.machine %>                      |
      | p             | {"spec":{"providerID":"invalid"}}      |
      | type          | merge                                  |
      | n             | openshift-machine-api                  |
    Then the step should succeed
    And I wait up to 30 seconds for the steps to pass:
    """
    When I run the :describe admin command with:
      | resource      | machine                                |
      | name          | <%= cb.machine %>                      |
      | n             | openshift-machine-api                  |
    Then the step should succeed
    And the output should match "Provider ID:\s+<%= cb.providerID %>"
    """

  # @author miyadav@redhat.com
  # @case_id OCP-27627
  @admin
  Scenario: Verify all machine instance-state should be consistent with their providerStats.instanceState
    Given I have an IPI deployment
    And evaluation of `BushSlicer::Machine.list(user: admin, project: project('openshift-machine-api'))` is stored in the :machines clipboard
    Then the expression should be true> cb.machines.select{|m|m.instance_state == m.annotation_instance_state}.count == cb.machines.count

  # @author miyadav@redhat.com
  # @case_id OCP-27609
  @admin
  @destructive
  Scenario: Scaling a machineset with providerSpec.publicIp set to true
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    And admin ensures machine number is restored after scenario

    Given I clone a machineset and name it "machineset-clone-27609"
    Then as admin I successfully merge patch resource "machineset/machineset-clone-27609" with:
      | {"spec":{"template": {"spec":{"providerSpec":{"value":{"publicIP": true}}}}}} |
    And I scale the machineset to +2
    Then the machineset should have expected number of running machines

  # @author miyadav@redhat.com
  # @case_id OCP-24363
  @admin
  @destructive
  Scenario: [MAO] Reconciling machine taints with nodes
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    And admin ensures machine number is restored after scenario

    Given I clone a machineset and name it "machineset-24363"
    And evaluation of `machine_set.machines.first.node_name` is stored in the :noderef_name clipboard
    And evaluation of `machine_set.machines.first.name` is stored in the :machine_name clipboard

    Given I saved following keys to list in :taintsid clipboard:
      | {"spec":{"taints": [{"effect": "NoExecute","key": "role","value": "master"}]}}  | |
      | {"spec":{"taints": [{"effect": "NoSchedule","key": "role","value": "master"}]}} | |

    And I use the "openshift-machine-api" project
    Then I repeat the following steps for each :id in cb.taintsid:
    """
    Given as admin I successfully merge patch resource "machine/<%= cb.machine_name %>" with:
      | #{cb.id} |
    Then the step should succeed
    """
    When I run the :describe admin command with:
      | resource | node                 |
      | name     |<%= cb.noderef_name %>|
    Then the output should contain:
      | role=master:NoExecute |
      | role=master:NoSchedule|

  # @author zhsun@redhat.com
  @admin
  @destructive
  Scenario Outline: Required configuration should be added to the ProviderSpec to enable spot instances
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And admin ensures machine number is restored after scenario

    #Create a spot machineset
    Given I use the "openshift-machine-api" project
    Given I create a spot instance machineset and name it "<machineset_name>" on <iaas_type>
    And evaluation of `machine_set.machines.first.node_name` is stored in the :noderef_name clipboard
    And evaluation of `machine_set.machines.first.name` is stored in the :machine_name clipboard

    #Check machine and node were labelled as an `interruptible-instance`
    When I run the :describe admin command with:
      | resource | machine                |
      | name     | <%= cb.machine_name %> |
    Then the step should succeed
    And the output should match "machine.openshift.io/interruptible-instance"
    When I run the :describe admin command with:
      | resource | node                   |
      | name     | <%= cb.noderef_name %> |
    Then the step should succeed
    And the output should match "machine.openshift.io/interruptible-instance="
    And "machine-api-termination-handler" daemonset becomes ready in the "openshift-machine-api" project
    And 1 pod becomes ready with labels:
      | k8s-app=termination-handler |

    # Create clusterautoscaler
    Given I obtain test data file "cloud/cluster-autoscaler.yml"
    When I run the :create admin command with:
      | f | cluster-autoscaler.yml |
    Then the step should succeed
    And admin ensures "default" clusterautoscaler is deleted after scenario
    And 1 pod becomes ready with labels:
      | cluster-autoscaler=default,k8s-app=cluster-autoscaler |

    # Create machineautoscaler
    Given I obtain test data file "cloud/machine-autoscaler.yml"
    When I run oc create over "machine-autoscaler.yml" replacing paths:
      | ["metadata"]["name"]               | maotest           |
      | ["spec"]["minReplicas"]            | 1                 |
      | ["spec"]["maxReplicas"]            | 3                 |
      | ["spec"]["scaleTargetRef"]["name"] | <machineset_name> |
    Then the step should succeed
    And admin ensures "maotest" machineautoscaler is deleted after scenario

    # Create workload
    Given I obtain test data file "cloud/autoscaler-auto-tmpl.yml"
    When I run the :create admin command with:
      | f | autoscaler-auto-tmpl.yml |
    Then the step should succeed
    And admin ensures "workload" job is deleted from the "openshift-machine-api" project after scenario

    # Verify machineset has scaled
    Given I wait up to 300 seconds for the steps to pass:
    """
    Then the expression should be true> machine_set.desired_replicas(cached: false) == 3
    """
    Then the machineset should have expected number of running machines

    # Delete workload
    Given admin ensures "workload" job is deleted from the "openshift-machine-api" project
    # Check cluster auto scales down
    And I wait up to 300 seconds for the steps to pass:
    """
    Then the expression should be true> machine_set.desired_replicas(cached: false) == 1
    """
    Then the machineset should have expected number of running machines

    # Check autoscaler taints are deleted when min node is reached
    Given I store the last provisioned machine in the :machine clipboard
    And evaluation of `machine(cb.machine).node_name` is stored in the :noderef_name clipboard
    When I run the :describe admin command with:
      | resource | node                  |
      | name     | <%= cb.noderef_name%> |
    Then the step should succeed
    And the output should not contain:
      | DeletionCandidateOfClusterAutoscaler |
      | ToBeDeletedByClusterAutoscaler       |

    Examples:
      | iaas_type | machineset_name        |
      | aws       | machineset-clone-29199 | # @case_id OCP-29199
      | gcp       | machineset-clone-32126 | # @case_id OCP-32126
      | azure     | machineset-clone-33040 | # @case_id OCP-33040

  # @author zhsun@redhat.com
  # @case_id OCP-32620
  @admin
  @destructive
  Scenario: Labels specified in a machineset should propagate to nodes
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    And admin ensures machine number is restored after scenario

    Given I clone a machineset and name it "machineset-clone-32620"
    Given as admin I successfully merge patch resource "machineset/machineset-clone-32620" with:
      | {"spec":{"template":{"spec":{"metadata":{"labels":{"node-role.kubernetes.io/infra": ""}}}}}} |
    Then the step should succeed

    Given I scale the machineset to +1
    Then the step should succeed
    And the machineset should have expected number of running machines

    #Check labels are propagate to nodes
    Given I store the last provisioned machine in the :machine clipboard
    And evaluation of `machine(cb.machine).node_name` is stored in the :noderef_name clipboard
    When I run the :describe admin command with:
      | resource | node                   |
      | name     | <%= cb.noderef_name %> |
    Then the step should succeed
    And the output should match "node-role.kubernetes.io/infra="

  # @author miyadav@redhat.com
  @admin
  @destructive
  Scenario Outline: Implement defaulting machineset values for AWS
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    Then admin ensures machine number is restored after scenario
    
    Given I store the last provisioned machine in the :machine clipboard
    When evaluation of `machine(cb.machine).aws_ami_id` is stored in the :default_ami_id clipboard
    And evaluation of `machine(cb.machine).aws_availability_zone` is stored in the :default_availability_zone clipboard
    And evaluation of `machine(cb.machine).aws_subnet` is stored in the :default_subnet clipboard
    And evaluation of `machine(cb.machine).aws_iamInstanceProfile` is stored in the :default_iamInstanceProfile clipboard
    Then admin ensures "<name>" machineset is deleted after scenario
    
    Given I obtain test data file "cloud/ms-aws/<file_name>"
    When I run oc create over "<file_name>" replacing paths:
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-cluster"]           | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["iamInstanceProfile"]["id"]         | <%= cb.default_iamInstanceProfile %>        |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"]        | <name>                                      |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-cluster"]    | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["ami"]["id"]                        | <%= cb.default_ami_id %>                    |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["placement"]["availabilityZone"]    | <%= cb.default_availability_zone %>         |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["subnet"]["id"]                     | <%= cb.default_subnet %>                    |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-machineset"] | <name>                                      |
      | ["metadata"]["name"]                                                                      | <name>                                      |
 
     
    Then I store the last provisioned machine in the :machine_latest clipboard
    And I wait up to 300 seconds for the steps to pass:
    """
    Then the expression should be true> machine(cb.machine_latest).phase(cached: false) == "Running"
    """

    When I run the :describe admin command with:
      | resource | machine                  |
      | name     | <%= cb.machine_latest %> |
    Then the step should succeed
    And the output should contain:
      | <Validation> |

    Examples:
      | name                    | file_name                 | Validation                    |
      | default-valued-32269    | ms_default_values.yaml    | Placement                     | # @case_id OCP-32269
      | tenancy-dedicated-37132 | ms_tenancy_dedicated.yaml | Tenancy:            dedicated | # @case_id OCP-37132
      | default-valued-42346    | ms_default_values.yaml    | Instance Type:  m5.large      | # @case_id OCP-42346

  # @author miyadav@redhat.com
  # @case_id OCP-33056
  @admin
  @destructive
  Scenario: Implement defaulting machineset values for GCP
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    Then admin ensures machine number is restored after scenario

    Given I store the last provisioned machine in the :machine clipboard
    When evaluation of `machine(cb.machine).gcp_region` is stored in the :default_region clipboard
    And evaluation of `machine(cb.machine).gcp_zone` is stored in the :default_zone clipboard
    And evaluation of `machine(cb.machine).gcp_service_account` is stored in the :default_service_account clipboard
    Then admin ensures "default-valued-33056" machineset is deleted after scenario

    Given I obtain test data file "cloud/ms-gcp/ms_default_values.yaml"
    When I run oc create over "ms_default_values.yaml" replacing paths:
      | n                                                                                         | openshift-machine-api                                |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-cluster"]           | <%= infrastructure("cluster").infra_name %>          |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"]        | default-valued-33056                                 |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-cluster"]    | <%= infrastructure("cluster").infra_name %>          |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["region"]                           | <%= cb.default_region %>                             |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["serviceAccounts"][0]["email"]      | <%=  cb.default_service_account[0].fetch("email") %> | 
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["zone"]                             | <%= cb.default_zone %>                               |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-machineset"] | default-valued-33056                                 |
    Then the step should succeed

    # Verify machine could be created successful
    And I wait up to 300 seconds for the steps to pass:
    """
    Then the expression should be true> machine_set("default-valued-33056").desired_replicas(cached: false) == 1
    """
    Then the machineset should have expected number of running machines

  # @author miyadav@redhat.com
  @admin
  @destructive
  Scenario Outline: Implement defaulting machineset values for azure
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    Then admin ensures machine number is restored after scenario

    Given I store the last provisioned machine in the :machine clipboard
    Then evaluation of `machine(cb.machine).azure_location` is stored in the :default_location clipboard
    And admin ensures "<name>" machineset is deleted after scenario

    Given I obtain test data file "cloud/ms-azure/<file_name>"
    When I run oc create over "<file_name>" replacing paths:
      | n                                                                                         | openshift-machine-api                       |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-cluster"]           | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"]        | <name>                                      |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-cluster"]    | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["location"]                         | <%= cb.default_location %>                  |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-machineset"] | <name>                                      |
      | ["metadata"]["name"]                                                                      | <name>                                      |
    Then the step should succeed
  
    Then I store the last provisioned machine in the :machine_latest clipboard
    And I wait up to 400 seconds for the steps to pass:
    """
    Then the expression should be true> machine(cb.machine_latest).phase(cached: false) == "Running"
    """
   
    When I run the :describe admin command with:
      | resource | machine                  |
      | name     | <%= cb.machine_latest %> |
    Then the step should succeed
    And the output should contain:
      | <Validation> |

    Examples:
      | name                    | file_name               | Validation                |
      | default-valued-33058    | ms_default_values.yaml  | Public IP                 | # @case_id OCP-33058
      | encrypt-at-rest-39639   | ms_encrypt_at_rest.yaml | Encryption At Host:  true | # @case_id OCP-39639

  # @author miyadav@redhat.com
  # @case_id OCP-33455
  @admin
  Scenario: Run machine api Controllers using leader election
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project

    Given a pod becomes ready with labels:
      | api=clusterapi, k8s-app=controller |

    And I saved following keys to list in :containers clipboard:
      | machine-controller     | |
      | machineset-controller  | |
      | nodelink-controller    | |

    Then I repeat the following steps for each :id in cb.containers:
    """
    When I run the :logs admin command with:
      | resource_name | <%= pod.name %> |
      | c             | #{cb.id}        |
    Then the output should match:
      | attempting to acquire leader lease (.*)openshift-machine-api/cluster-api-provider |
    """

  # @author zhsun@redhat.com
  # @case_id OCP-34718
  @admin
  Scenario: Node labels and Affinity definition in PV should match
    Given I have a project

    # Create a pvc
    Given I obtain test data file "cloud/pvc-34718.yml"
    When I run the :create client command with:
      | f | pvc-34718.yml |
    Then the step should succeed

    # Create a pod
    Given I obtain test data file "cloud/pod-34718.yml"
    When I run the :create client command with:
      | f | pod-34718.yml |
    Then the step should succeed

    #Check node labels and affinity definition in PV are match
    Given the pod named "task-pv-pod" becomes ready
    And I use the "<%= pod.node_name %>" node
    And evaluation of `node.region` is stored in the :default_region clipboard
    And evaluation of `node.zone` is stored in the :default_zone clipboard
    When I run the :describe admin command with:
      | resource | pv |
    Then the step should succeed
    And the output should contain:
      | region in [<%= cb.default_region %>] |

  # @author miyadav@redhat.com
  @admin
  @destructive
  Scenario Outline: Implement defaulting machineset values for vsphere
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    And I use the "openshift-machine-api" project
    Then admin ensures machine number is restored after scenario

    Given I store the last provisioned machine in the :machine clipboard
    And evaluation of `machine(cb.machine).vsphere_datacenter` is stored in the :datacenter clipboard
    And evaluation of `machine(cb.machine).vsphere_datastore` is stored in the :datastore clipboard
    And evaluation of `machine(cb.machine).vsphere_folder` is stored in the :folder clipboard
    And evaluation of `machine(cb.machine).vsphere_resourcePool` is stored in the :resourcePool clipboard
    And evaluation of `machine(cb.machine).vsphere_server` is stored in the :server clipboard
    And evaluation of `machine(cb.machine).vsphere_diskGiB` is stored in the :diskGiB clipboard
    And evaluation of `machine(cb.machine).vsphere_memoryMiB` is stored in the :memoryMiB clipboard
    And evaluation of `machine(cb.machine).vsphere_template` is stored in the :template clipboard
    Then admin ensures "<name>" machineset is deleted after scenario

    Given I obtain test data file "cloud/ms-vsphere/ms_default_values.yaml"
    When I run oc create over "ms_default_values.yaml" replacing paths:
      | n                                                                                         | openshift-machine-api                       |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-cluster"]           | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"]        | <name>                                      |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-cluster"]    | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["workspace"]["datacenter"]          | <%= cb.datacenter %>                        |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["workspace"]["datastore"]           | <%= cb.datastore %>                         |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["workspace"]["folder"]              | <%= cb.folder %>                            |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["workspace"]["resourcePool"]        | <%= cb.resourcePool %>                      |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["workspace"]["server"]              | <%= cb.server %>                            |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["diskGiB"]                          | <diskGiB>                                   |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["memoryMiB"]                        | <%= cb.memoryMiB %>                         |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["template"]                         | <template>                                  |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-machineset"] | <name>                                      |
      | ["metadata"]["name"]                                                                      | <name>                                      |
    Then the step should succeed

    And I wait up to 120 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource | machine |
    Then the step should succeed
    And the output should contain:
      | Provisioned  |
    """

    Examples:
      | name                         | template                           | diskGiB           |
      | default-valued-33380         | <%= cb.template %>                 | <%= cb.diskGiB %> | # @case_id OCP-33380
      | default-valued-windows-35421 | openshift-qe-template-windows-2019 | 135               | # @case_id OCP-35421

  # @author miyadav@redhat.com
  # @case_id OCP-36489
  @admin
  Scenario: [Azure] Machineset should not be created when publicIP:true in disconnected Azure enviroment
    Given I have an IPI deployment
    And I switch to cluster admin pseudo user
    Then I use the "openshift-machine-api" project

    Given I obtain test data file "cloud/ms-azure/ms_disconnected_env.yaml"
    When I run oc create over "ms_disconnected_env.yaml" replacing paths:
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-cluster"]           | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["selector"]["matchLabels"]["machine.openshift.io/cluster-api-machineset"]        | disconnected-azure-36489                    |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-cluster"]    | <%= infrastructure("cluster").infra_name %> |
      | ["spec"]["template"]["metadata"]["labels"]["machine.openshift.io/cluster-api-machineset"] | disconnected-azure-36489                    |
      | ["spec"]["template"]["spec"]["providerSpec"]["value"]["publicIP"]                         | true                                        |

    And the output should contain:
      | Forbidden: publicIP is not allowed in Azure disconnected installation |

