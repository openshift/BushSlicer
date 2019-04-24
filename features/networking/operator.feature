Feature: Operator related networking scenarios

  # @auther anusaxen@redhat.com
  # @case_id OCP-22704
  @admin
  Scenario: The clusteroperator should be able to reflect the network operator version corresponding to the OCP version

    Given the master version > "3.11"
    #Getting OCP version
    Given evaluation of `cluster_version('version').version` is stored in the :ocp_version clipboard
    And evaluation of `cluster_operator('network').condition(type: 'Available')` is stored in the :operator_status clipboard
    #Making sure that network operator AVAILABLE status value is True
    Then the expression should be true> cb.operator_status["status"]=="True"
    #Confirm whether network operator version matches with ocp version
    And the expression should be true> cluster_operator('network').version_exists?(version: cb.ocp_version)

  # @auther anusaxen@redhat.com
  # @case_id OCP-22706
  @admin
  @destructive
  Scenario: The clusteroperator should be able to reflect the correct version field post bad network operator config

    Given the master version >= "4.0"
    #Getting OCP version
    Given evaluation of `cluster_version('version').version` is stored in the :ocp_version clipboard
<<<<<<< HEAD
    #Making sure that operator is not Degraded before proceesing further steps
    And evaluation of `cluster_operator('network').condition(type: 'Degraded')` is stored in the :Degraded_status_before_patch clipboard
    Then the expression should be true> cb.Degraded_status_before_patch["status"]=="False"
=======
    #Making sure that operator is not Failing before proceesing further steps
    And evaluation of `cluster_operator('network').condition(type: 'Failing')` is stored in the :failing_status_before_patch clipboard
    Then the expression should be true> cb.failing_status_before_patch["status"]=="False"
>>>>>>> e96c99592f57c99857183b780d5c9f6471a84fdb
    #Editing networks.config.openshift.io cluster to reflect bad config like changing networktype from OpenShiftSDN to OpenShift
    When I run the :patch admin command with:
      | resource      | networks.config.openshift.io         |
      | resource_name | cluster                              |
      | p             | {"spec":{"networkType":"OpenShift"}} |
      | type          | merge                                |
    Then the step should succeed

<<<<<<< HEAD
    #Registering clean-up steps to move networkType back to OpenShiftSDN and to check Degraded status is False before test exits
=======
    #Registering clean-up steps to move networkType back to OpenShiftSDN and to check Failing status is False before test exits
>>>>>>> e96c99592f57c99857183b780d5c9f6471a84fdb
    Given I register clean-up steps:
    """
    When I run the :patch admin command with:
      | resource      | networks.config.openshift.io            |
      | resource_name | cluster                                 |
      | p             | {"spec":{"networkType":"OpenShiftSDN"}} |
      | type          | merge                                   |
    Then the step should succeed
    20 seconds have passed
<<<<<<< HEAD
    evaluation of `cluster_operator('network').condition(type: 'Degraded',cached: false)` is stored in the :Degraded_status clipboard
    the expression should be true> cb.Degraded_status["status"]=="False"
    """
    #Normally it takes 5-10 seconds for network config update to reconcile across the cluster but taking 20 seconds wait to make sure that Degraded status becomes True post bad patch
    Given 20 seconds have passed
    And evaluation of `cluster_operator('network').condition(type: 'Degraded',cached: false)` is stored in the :Degraded_status_post_patch clipboard
    Then the expression should be true> cb.Degraded_status_post_patch["status"]=="True"
    And the expression should be true> cluster_operator('network').version_exists?(version: cb.ocp_version)
=======
    evaluation of `cluster_operator('network').condition(type: 'Failing',cached: false)` is stored in the :failing_status clipboard
    the expression should be true> cb.failing_status["status"]=="False"
    """
    #Normally it takes 5-10 seconds for network config update to reconcile across the cluster but taking 20 seconds wait to make sure that Failing status becomes True post bad patch
    Given 20 seconds have passed
    And evaluation of `cluster_operator('network').condition(type: 'Failing',cached: false)` is stored in the :failing_status_post_patch clipboard
    Then the expression should be true> cb.failing_status_post_patch["status"]=="True"
    And the expression should be true> cluster_operator('network').version_exists?(version: cb.ocp_version)

  # @author bmeng@redhat.com
  # @case_id OCP-22201
  @admin
  Scenario: Should have a clusteroperator object created under config.openshift.io api group for network-operator
    Given the master version >= "4.0"
    # Check the operator object has version
    Given the expression should be true> cluster_operator('network').versions.length > 0
    # Check the operator object has status for Failing|Progressing|Available
    And the expression should be true> cluster_operator('network').condition(type: 'Available')['status'] == "True"
    And the expression should be true> cluster_operator('network').condition(type: 'Failing')['status'] == "False"
    And the expression should be true> cluster_operator('network').condition(type: 'Progressing')['status'] == "False"


  # @author bmeng@redhat.com
  # @case_id OCP-22419
  @admin
  @destructive
  Scenario: The clusteroperator should be able to reflect the realtime status of the network when the config has problem
    Given the master version >= "4.0"
    # Check that the operator is not failing
    Given the expression should be true> cluster_operator('network').condition(type: 'Failing')['status'] == "False"
    # Copy the value of the networktype for backup
    When I run the :get admin command with:
      | resource      | network.config.openshift.io |
      | resource_name | cluster                     |
      | template      | {{.spec.networkType}}       |
    Then the step should succeed
    And evaluation of `@result[:response]` is stored in the :network_type clipboard
    # Do some modification on the network.config.openshift.io
    When I run the :patch admin command with:
      | resource      | network.config.openshift.io     |
      | resource_name | cluster                         |
      | p             | {"spec":{"networkType":"None"}} |
      | type          | merge                           |
    Then the step should succeed
    Given I register clean-up steps:
    """
    When I run the :patch admin command with:
      | resource      | network.config.openshift.io                       |
      | resource_name | cluster                                           |
      | p             | {"spec":{"networkType":"<%= cb.network_type %>"}} |
      | type          | merge                                             |
    Then the step should succeed
    """
    # Check that the operator status reflect the problem
    Given I wait up to 10 seconds for the steps to pass:
    """
    Given the status of condition "Failing" for network operator is :True
    And the status of condition "Available" for network operator is :True
    """
    # Change the network.config.openshift.io back
    When I run the :patch admin command with:
      | resource      | network.config.openshift.io                       |
      | resource_name | cluster                                           |
      | p             | {"spec":{"networkType":"<%= cb.network_type %>"}} |
      | type          | merge                                             |
    Then the step should succeed
    # Check that the operator status
    Given I wait up to 20 seconds for the steps to pass:
    """
    Given the status of condition "Failing" for network operator is :False
    And the status of condition "Available" for network operator is :True
    """

  # @author bmeng@redhat.com
  # @case_id OCP-22202
  @admin
  @destructive
  Scenario: The clusteroperator should be able to reflect the realtime status of the network when a new node added
    Given the master version >= "4.0"
    # Check that the operator is not progressing
    Given the expression should be true> cluster_operator('network').condition(type: 'Progressing')['status'] == "False"

    # Record the original machine replica and scale it up to number +1
    When I run the :get admin command with:
      | resource | machineset                         |
      | n        | openshift-machine-api              |
      | template | {{(index .items 0).metadata.name}} |
    Then the step should succeed
    And evaluation of `@result[:stdout]` is stored in the :machineset clipboard
    When I run the :get admin command with:
      | resource      | machineset            |
      | n             | openshift-machine-api |
      | resource_name | <%= cb.machineset %>  |
      | template      | {{.spec.replicas}}    |
    Then the step should succeed
    And evaluation of `@result[:response].to_i` is stored in the :original_replicas clipboard
    And evaluation of `@result[:response].to_i + 1` is stored in the :desired_replicas clipboard
    When I run the :scale admin command with:
      | resource | machineset                 |
      | name     | <%= cb.machineset %>       |
      | replicas | <%= cb.desired_replicas %> |
      | n        | openshift-machine-api      |
    Then the step should succeed
    # Scale down the machine after the scenario
    Given I register clean-up steps:
    """
    When I run the :scale admin command with:
      | resource | machineset                  |
      | name     | <%= cb.machineset %>        |
      | replicas | <%= cb.original_replicas %> |
      | n        | openshift-machine-api       |
    Then the step should succeed
    """

    # Check that the status of Progressing is truned to True during the new node provisioning
    Given I wait up to 360 seconds for the steps to pass:
    """
    Given the status of condition "Progressing" for network operator is :True
    """

    And I wait up to 60 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource      | machineset                |
      | resource_name | <%= cb.machineset %>      |
      | n             | openshift-machine-api     |
      | template      | {{.status.readyReplicas}} |
    Then the expression should be true> @result[:response].to_i == cb.desired_replicas
    """

    # Check that the status of Progressing is back to False once the node provision finished
    And I wait up to 120 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource | node |
    Then the step should succeed
    And the output should not contain "NotReady"
    Given the status of condition "Progressing" for network operator is :False
    """
>>>>>>> e96c99592f57c99857183b780d5c9f6471a84fdb
