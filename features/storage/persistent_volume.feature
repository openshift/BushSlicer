Feature: Persistent Volume Claim binding policies

  # @author jhou@redhat.com
  # @author lxia@redhat.com
  # @author chaoyang@redhat.com
  @admin
  Scenario Outline: PVC with one accessMode can bind PV with all accessMode
    Given I have a project

    # Create 2 PVs
    # Create PV with all accessMode
    When admin creates a PV from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/nfs/auto/pv-template-all-access-modes.json" where:
      | ["metadata"]["name"]         | pv1-<%= project.name %> |
      | ["spec"]["storageClassName"] | sc-<%= project.name %>  |
    Then the step should succeed
    # Create PV without accessMode3
    When admin creates a PV from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/nfs/auto/pv.json" where:
      | ["metadata"]["name"]         | pv2-<%= project.name %> |
      | ["spec"]["accessModes"][0]   | <accessMode1>           |
      | ["spec"]["accessModes"][1]   | <accessMode2>           |
      | ["spec"]["storageClassName"] | sc-<%= project.name %>  |
    Then the step should succeed

    # Create PVC with accessMode3
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"]         | mypvc                  |
      | ["spec"]["accessModes"][0]   | <accessMode3>          |
      | ["spec"]["storageClassName"] | sc-<%= project.name %> |
    Then the step should succeed

    And the "mypvc" PVC becomes bound to the "pv1-<%= project.name %>" PV
    And the "pv2-<%= project.name %>" PV status is :available

    Examples:
      | accessMode1   | accessMode2   | accessMode3   |
      | ReadOnlyMany  | ReadWriteMany | ReadWriteOnce | # @case_id OCP-9702
      | ReadWriteOnce | ReadOnlyMany  | ReadWriteMany | # @case_id OCP-10680
      | ReadWriteMany | ReadWriteOnce | ReadOnlyMany  | # @case_id OCP-11168

  # @author yinzhou@redhat.com
  # @case_id OCP-11933
  Scenario: deployment hook volume inheritance -- with persistentvolumeclaim Volume
    Given I have a project
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"] | nfsc |
    Then the step should succeed
    And I wait for the "nfsc" pvc to appear

    When I run the :create client command with:
      | f | https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/cases/510610/hooks-with-nfsvolume.json |
    Then the step should succeed
  ## mount should be correct to the pod, no-matter if the pod is completed or not, check the case checkpoint
    And I wait for the steps to pass:
    """
    When I get project pod named "hooks-1-hook-pre" as YAML
    Then the output by order should match:
      | - mountPath: /opt1     |
      | name: v1               |
      | persistentVolumeClaim: |
      | claimName: nfsc        |
    """

  # @author lxia@redhat.com
  @admin
  Scenario Outline: PV can not bind PVC which request more storage
    Given I have a project
    # PV is 100Mi and PVC is 1Gi
    When admin creates a PV from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/nfs/auto/pv-template.json" where:
      | ["metadata"]["name"]            | pv-<%= project.name %> |
      | ["spec"]["accessModes"][0]      | <access_mode>          |
      | ["spec"]["capacity"]["storage"] | 100Mi                  |
      | ["spec"]["storageClassName"]    | sc-<%= project.name %> |
    Then the step should succeed
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"]         | mypvc                  |
      | ["spec"]["accessModes"][0]   | <access_mode>          |
      | ["spec"]["storageClassName"] | sc-<%= project.name %> |
    Then the step should succeed
    And the "pv-<%= project.name %>" PV status is :available
    And the "mypvc" PVC becomes :pending

    Examples:
      | access_mode   |
      | ReadOnlyMany  | # @case_id OCP-26880
      | ReadWriteMany | # @case_id OCP-26881
      | ReadWriteOnce | # @case_id OCP-26879


  # @author lxia@redhat.com
  @admin
  Scenario Outline: PV can not bind PVC with mismatched accessMode
    Given I have a project
    When admin creates a PV from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/nfs/auto/pv-template.json" where:
      | ["metadata"]["name"]         | pv-<%= project.name %> |
      | ["spec"]["accessModes"][0]   | <pv_access_mode>       |
      | ["spec"]["storageClassName"] | sc-<%= project.name %> |
    Then the step should succeed
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"]         | mypvc1                 |
      | ["spec"]["accessModes"][0]   | <pvc_access_mode1>     |
      | ["spec"]["storageClassName"] | sc-<%= project.name %> |
    Then the step should succeed
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"]         | mypvc2                 |
      | ["spec"]["accessModes"][0]   | <pvc_access_mode2>     |
      | ["spec"]["storageClassName"] | sc-<%= project.name %> |
    Then the step should succeed
    And the "pv-<%= project.name %>" PV status is :available
    And the "mypvc1" PVC becomes :pending
    And the "mypvc2" PVC becomes :pending

    Examples:
      | pv_access_mode | pvc_access_mode1 | pvc_access_mode2 |
      | ReadOnlyMany   | ReadWriteMany    | ReadWriteOnce    | # @case_id OCP-26882
      | ReadWriteMany  | ReadWriteOnce    | ReadOnlyMany     | # @case_id OCP-26883
      | ReadWriteOnce  | ReadOnlyMany     | ReadWriteMany    | # @case_id OCP-26884


  # @author chaoyang@redhat.com
  # @case_id OCP-9937
  @admin
  @destructive
  Scenario: PV and PVC bound and unbound many times
    Given default storage class is patched to non-default
    Given I have a project
    And I have a NFS service in the project

    #Create 20 pv
    Given I run the steps 20 times:
    """
    When admin creates a PV from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/nfs/tc522215/pv.json" where:
      | ["spec"]["nfs"]["server"]  | <%= service("nfs-service").ip %> |
    Then the step should succeed
    """

    Given 20 PVs become :available within 20 seconds with labels:
      | usedFor=tc522215 |

    #Loop 5 times about pv and pvc bound and unbound
    Given I run the steps 5 times:
    """
    And I run the :create client command with:
      | f | https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/nfs/tc522215/pvc-20.json |
    Given 20 PVCs become :bound within 50 seconds with labels:
      | usedFor=tc522215 |
    Then I run the :delete client command with:
      | object_type | pvc |
      | all         | all |
    Given 20 PVs become :available within 500 seconds with labels:
      | usedFor=tc522215 |
    """

