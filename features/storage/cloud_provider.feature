Feature: kubelet restart and node restart

  # @author lxia@redhat.com
  @admin
  @destructive
  Scenario Outline: kubelet restart should not affect attached/mounted volumes
    Given admin creates a project with a random schedulable node selector
    And evaluation of `%w{ReadWriteOnce ReadWriteOnce ReadWriteOnce}` is stored in the :accessmodes clipboard
    And I run the steps 3 times:
    """
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"]                         | dynamic-pvc-#{cb.i}       |
      | ["spec"]["accessModes"][0]                   | #{cb.accessmodes[cb.i-1]} |
      | ["spec"]["resources"]["requests"]["storage"] | #{cb.i}Gi                 |
    Then the step should succeed
    And the "dynamic-pvc-#{cb.i}" PVC becomes :bound
    When I run the :get admin command with:
      | resource | pv |
    Then the output should contain:
      | dynamic-pvc-#{cb.i} |
    When I run oc create over "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pod.yaml" replacing paths:
      | ["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"] | dynamic-pvc-#{cb.i} |
      | ["metadata"]["name"]                                         | mypod#{cb.i}        |
      | ["spec"]["containers"][0]["volumeMounts"][0]["mountPath"]    | /mnt/<platform>     |
    Then the step should succeed
    Given the pod named "mypod#{cb.i}" becomes ready
    When I execute on the pod:
      | touch | /mnt/<platform>/testfile_before_restart_#{cb.i} |
    Then the step should succeed
    """
    # restart kubelet on the node
    Given I use the "<%= node.name %>" node
    And the node service is restarted on the host
    And I wait up to 120 seconds for the steps to pass:
    """
    Given I run the steps 3 times:
    <%= '"'*3 %>
    # verify previous created files still exist
    When I execute on the "mypod#{cb.i}" pod:
      | ls | /mnt/<platform>/testfile_before_restart_#{cb.i} |
    Then the step should succeed
    # write to the mounted storage
    When I execute on the "mypod#{cb.i}" pod:
      | touch | /mnt/<platform>/testfile_after_restart_#{cb.i} |
    Then the step should succeed
    <%= '"'*3 %>
    """

    Examples:
      | platform |
      | gce      | # @case_id OCP-11613
      | cinder   | # @case_id OCP-11317
      | aws      | # @case_id OCP-10907

  # @author wehe@redhat.com
  @admin
  @destructive
  Scenario Outline: kubelet restart should not affect attached/mounted volumes on IaaS
    Given admin creates a project with a random schedulable node selector
    When admin creates a StorageClass from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/storageClass.yaml" where:
      | ["metadata"]["name"] | sc-<%= project.name %>      |
      | ["provisioner"]      | kubernetes.io/<provisioner> |
    Then the step should succeed

    Given evaluation of `%w{ReadWriteOnce ReadWriteOnce ReadWriteOnce}` is stored in the :accessmodes clipboard
    And I run the steps 3 times:
    """
    When I create a dynamic pvc from "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pvc.json" replacing paths:
      | ["metadata"]["name"]                         | dpvc-#{cb.i}              |
      | ["spec"]["storageClassName"]                 | sc-<%= project.name %>    |
      | ["spec"]["accessModes"][0]                   | #{cb.accessmodes[cb.i-1]} |
      | ["spec"]["resources"]["requests"]["storage"] | #{cb.i}Gi                 |
    Then the step should succeed
    And the "dpvc-#{cb.i}" PVC becomes :bound
    When I run oc create over "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/storage/misc/pod.yaml" replacing paths:
      | ["spec"]["volumes"][0]["persistentVolumeClaim"]["claimName"] | dpvc-#{cb.i} |
      | ["metadata"]["name"]                                         | mypod#{cb.i} |
      | ["spec"]["containers"][0]["volumeMounts"][0]["mountPath"]    | /mnt/iaas    |
    Then the step should succeed
    And the pod named "mypod#{cb.i}" becomes ready

    When I execute on the pod:
      | touch | /mnt/iaas/testfile_before_restart_#{cb.i} |
    Then the step should succeed
    """

    # restart kubelet on the node
    Given I use the "<%= node.name %>" node
    And the node service is restarted on the host
    And I wait up to 120 seconds for the steps to pass:
    """
    # verify previous created files still exist
    Given I run the steps 3 times:
    <%= '"'*3 %>
    When I execute on the "mypod#{cb.i}" pod:
      | ls | /mnt/iaas/testfile_before_restart_#{cb.i} |
    Then the step should succeed
    # write to the mounted storage
    When I execute on the "mypod#{cb.i}" pod:
      | touch | /mnt/iaas/testfile_after_restart_#{cb.i} |
    Then the step should succeed
    <%= '"'*3 %>
    """

  Examples:
      | provisioner    |
      | vsphere-volume | # @case_id OCP-13631
      | azure-disk     | # @case_id OCP-13333

