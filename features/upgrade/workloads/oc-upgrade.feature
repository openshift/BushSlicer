Feature: basic verification for upgrade oc client testing
  # @author yinzhou@redhat.com
  @upgrade-prepare
  @users=upuser1,upuser2
  Scenario: Check some container related oc commands still work after upgrade - prepare
    Given I switch to the first user
    When I run the :new_project client command with:
      | project_name | workloads-upgrade |
    When I run the :new_app client command with:
      | template | httpd-example |
    Then the step should succeed

  # @author yinzhou@redhat.com
  # @case_id OCP-13032
  @upgrade-check
  @users=upuser1,upuser2
  Scenario: Check some container related oc commands still work after upgrade
    Given I switch to the first user
    When I use the "workloads-upgrade" project
    Given status becomes :running of 1 pods labeled:
      | name=httpd-example |
    When I run the :rsh client command with:
      | pod     | <%= pod.name %>            |
      | command | ls                         |
      | command | /etc                       |
    Then the step should succeed
    When I run the :exec client command with:
      | pod              | <%= pod.name %>   |
      | exec_command     | cat               |
      | exec_command_arg | /etc/hosts        |
    Then the output should contain:
      | localhost |
    And evaluation of `rand(5000..7999)` is stored in the :port1 clipboard
    When I run the :port_forward background client command with:
      | pod       | <%= pod.name %>          |
      | port_spec | <%= cb[:port1] %>:8080   |
      | _timeout  | 100                      |
    Then the step should succeed
    Given I wait up to 30 seconds for the steps to pass:
    """
    When I open web server via the "http://127.0.0.1:<%= cb[:port1] %>" url
    Then the step should succeed
    And the output should contain:
      | Welcome to your static httpd application on OpenShift |
    """

