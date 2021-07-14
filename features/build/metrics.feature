Feature: Builds and samples related metrics test

  # @author xiuwang@redhat.com
  # @case_id OCP-33220
  @admin
  @destructive
  Scenario: Alerts on imagestream import retries
    When as admin I successfully merge patch resource "config.samples.operator.openshift.io/cluster" with:
      | {"spec":{"samplesRegistry":"registry.unconnected.redhat.com"}} |
    And I register clean-up steps:
    """
    Given as admin I successfully merge patch resource "config.samples.operator.openshift.io/cluster" with:
      | {"spec":{"samplesRegistry": null}} |
    """
    Then I wait up to 120 seconds for the steps to pass:
    """
    When I run the :describe admin command with:
      | resource | imagestream |
      | name     | ruby        |
      | namespace| openshift   |
    Then the step should succeed
    And the output should contain:
      | Import failed |
    """

    And I switch to cluster admin pseudo user
    And I use the "openshift-monitoring" project
    When evaluation of `secret(service_account('prometheus-k8s').get_secret_names.find {|s| s.match('token')}).token` is stored in the :sa_token clipboard

    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/query?query=sum\(openshift_samples_retry_imagestream_import_total\) |
    Then the step should succeed
    And the output should match:
      | "status":"success".*value.*[0-9]* |
    """
    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/query?query=sum\(openshift_samples_failed_imagestream_import_info\) |
    Then the step should succeed
    And the output should match:
      | "status":"success".*value.*[0-9]* |
    """

  # @author xiuwang@redhat.com
  # @case_id OCP-33722
  @admin
  Scenario: Check build metrics
    Given I have a project
    When I run the :new_app client command with:
      | template | cakephp-mysql-example |
    Then the step should succeed
    And the "cakephp-mysql-example-1" build was created
    Given the "cakephp-mysql-example-1" build completed
    When I run the :new_app client command with:
      | template | jenkins-ephemeral |
    Then the step should succeed
    Given 1 pod becomes ready with labels:
      | deployment=jenkins-1 |
    When I run the :new_app client command with:
      | file | https://raw.githubusercontent.com/openshift/origin/master/examples/jenkins/pipeline/samplepipeline.yaml |
    Then the step should succeed
    When I run the :start_build client command with:
      | buildconfig | sample-pipeline |
    Then the step should succeed
    Given the "sample-pipeline-1" build was created
    When I run the :start_build client command with:
      | buildconfig | nodejs-postgresql-example |
    Then the step should succeed
    Given the "nodejs-postgresql-example-1" build was created

    And I switch to cluster admin pseudo user
    And I use the "openshift-monitoring" project
    When evaluation of `secret(service_account('prometheus-k8s').get_secret_names.find {|s| s.match('token')}).token` is stored in the :sa_token clipboard

    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/label/__name__/values |
    Then the step should succeed
    And the output should contain:
      | openshift_build_created_timestamp_seconds   |
      | openshift_build_start_timestamp_seconds     |
      | openshift_build_completed_timestamp_seconds |
      | openshift_build_duration_seconds            |
      | openshift_build_metadata_generation_info    |
      | openshift_build_labels                      |
      | openshift_build_status_phase_total          |
    """
    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/query?query=openshift_build_created_timestamp_seconds |
    Then the step should succeed
    And the output should contain:
      | cakephp-mysql-example-1     |
      | sample-pipeline-1           |
      | nodejs-postgresql-example-1 |
    """
    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/query?query=openshift_build_duration_seconds |
    Then the step should succeed
    And the output should contain:
      | cakephp-mysql-example-1     |
      | nodejs-postgresql-example-1 |
    """

  # @author xiuwang@redhat.com
  # @case_id OCP-33770
  @admin
  Scenario: Adding metric for registry v1 protocol imports
    Given I have a project
    #Importing a image with regsitry v1 api
    When I run the :import_image client command with:
      | image_name | myv1image                                                         |
      | from       | devexp.registry-v1.qe.devcluster.openshift.com:5000/imagev1/test1 |
      | confirm    | true                                                              |
      | all        | true                                                              |
      | insecure   | true                                                              |
    Then the step should succeed

    And I switch to cluster admin pseudo user
    And I use the "openshift-monitoring" project
    When evaluation of `secret(service_account('prometheus-k8s').get_secret_names.find {|s| s.match('token')}).token` is stored in the :sa_token clipboard

    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/query?query=apiserver_v1_image_imports_total |
    Then the step should succeed
    And the output should match:
      | "repository":"devexp.registry-v1.qe.devcluster.openshift.com:5000/imagev1/test1".*value.*[0-9]* |
    """

  # @author xiuwang@redhat.com
  # @case_id OCP-25598
  @admin
  @destructive
  Scenario: Monitoring, Alerting, and Degraded Status Reporting-Samples-operator
    When as admin I successfully merge patch resource "config.samples.operator.openshift.io/cluster" with:
      | {"spec":{"samplesRegistry":"registry.unconnected.redhat.com"}} |
    And I register clean-up steps:
    """
    Given as admin I successfully merge patch resource "config.samples.operator.openshift.io/cluster" with:
      | {"spec":{"samplesRegistry": null}} |
    """

    And I switch to cluster admin pseudo user
    And I use the "openshift-monitoring" project
    When evaluation of `secret(service_account('prometheus-k8s').get_secret_names.find {|s| s.match('token')}).token` is stored in the :sa_token clipboard

    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/label/__name__/values |
    Then the step should succeed
    And the output should contain:
      | openshift_samples_degraded_info                  |
      | openshift_samples_failed_imagestream_import_info |
      | openshift_samples_invalidconfig_info             |
      | openshift_samples_invalidsecret_info             |
    """
    And I wait up to 240 seconds for the steps to pass:
    """
    When I run the :exec admin command with:
      | n                | openshift-monitoring |
      | pod              | prometheus-k8s-0     |
      | c                | prometheus           |
      | oc_opts_end      |                      |
      | exec_command     | sh                   |
      | exec_command_arg | -c                   |
      | exec_command_arg | curl -k -H "Authorization: Bearer <%= cb.sa_token %>" https://prometheus-k8s.openshift-monitoring.svc:9091/api/v1/query?query=openshift_samples_failed_imagestream_import_info |
    Then the step should succeed
    And the output should match:
      | "name":"ruby","namespace":"openshift-cluster-samples-operator".*value.*"1"|
    """
