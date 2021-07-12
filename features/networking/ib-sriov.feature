Feature: Sriov IB related scenarios

  # @author zzhao@redhat.com
  @destructive
  @admin
  Scenario Outline: IPoIB and IB mode for CX4/CX5/CX6 card
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/ib/<cardname>/<cardname>-ib.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | <cardname>-ib.yaml       |
      | cr_name       | ib-<cardname>            |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 900 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | ib-<cardname>         |
      | vfID: 1               |
      | syncStatus: Succeeded |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/ib/<cardname>/sriovibnetwork-<cardname>.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | sriovibnetwork-<cardname>.yaml |
      | cr_name       | ib-<cardname>                  |
      | resource_type | sriovibnetwork                 |
      | project       | <%= cb.usr_project%>           |
    Then the step should succeed

    And admin checks that the "ib-<cardname>" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    #create one ipoib pod
    Given I obtain test data file "networking/sriov/ib/cx4/pod_iboip.yaml"
    When I run oc create over "pod_iboip.yaml" replacing paths:
      | ["metadata"]["annotations"]["k8s.v1.cni.cncf.io/networks"] | ib-<cardname> |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=ipoib |
    When I execute on the pod:
      | ip | a |
    Then the output should contain "10.56.21"
    #create one IB pod
    Given I obtain test data file "networking/sriov/ib/cx4/pod_ib.yaml"
    When I run oc create over "pod_ib.yaml" replacing paths:
      | ["spec"]["containers"][0]["resources"]["requests"] | openshift.io/<cardname>ib: "1" |
      | ["spec"]["containers"][0]["resources"]["limits"]   | openshift.io/<cardname>ib: "1" |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=ib |
    When I execute on the pod:
      | ls | /dev/ |
    Then the output should contain "infiniband"

    Examples:
      | cardname | 
      | cx4   | # @case_id OCP-33812
      | cx5   | # @case_id OCP-33813
      | cx6   | # @case_id OCP-33814

  # @author zzhao@redhat.com
  # @case_id OCP-33852
  @destructive
  @admin
  Scenario: Set the infiniband-guid for pod
    Given the sriov operator is running well
    Given I obtain test data file "networking/sriov/ib/cx6/cx6-ib.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | cx6-ib.yaml              |
      | cr_name       | ib-cx6                   |
      | resource_type | sriovnetworknodepolicies |
    Then the step should succeed
    And I wait up to 900 seconds for the steps to pass:
    """
    When I run the :get admin command with:
      | resource    | sriovnetworknodestates           |
      | namespace   | openshift-sriov-network-operator |
      | o           | yaml                             |
    Then the step should succeed
    And the output should contain:
      | ib-cx6                |
      | vfID: 1               |
      | syncStatus: Succeeded |
    """
    Given I switch to the first user
    And I have a project
    And evaluation of `project.name` is stored in the :usr_project clipboard
    Given I obtain test data file "networking/sriov/ib/cx6/sriovibnetwork-static.yaml"
    Given I create sriov resource with following:
      | cr_yaml       | sriovibnetwork-static.yaml |
      | cr_name       | ib-cx6                     |
      | resource_type | sriovibnetwork             |
      | project       | <%= cb.usr_project%>       |
    Then the step should succeed

    And admin checks that the "ib-cx6" network_attachment_definition exists in the "<%= cb.usr_project %>" project
    And I use the "<%= cb.usr_project%>" project
    Given I obtain test data file "networking/sriov/ib/cx6/pod-guid.yaml"
    When I run the :create client command with:
      | f | pod-guid.yaml |
    Then the step should succeed
    And a pod becomes ready with labels:
      | name=pod-guid |
    When I execute on the pod:
      | ip | a |
    Then the output should contain:
      | 192.168.1         |
      | 22:33:44:55:66:77 |
