Feature: oc import-image related feature
  # @author chaoyang@redhat.com
  # @case_id OCP-10585
  Scenario: Do not create tags for ImageStream if image repository does not have tags
    When I have a project
    Given I obtain test data file "image-streams/is_without_tags.json"
    And I run the :create client command with:
      | filename | is_without_tags.json |
    Then the step should succeed
    When I run the :get client command with:
      | resource      | imagestreams |
    Then the output should contain "hello-world"
    When I run the :get client command with:
      | resource_name   | hello-world  |
      | resource        | imagestreams     |
      | o               | yaml             |
    And the output should not contain "tags"

  # @author wjiang@redhat.com
  # @case_id OCP-10721
  Scenario: Could not import the tag when reference is true
    Given I have a project
    Given I obtain test data file "image-streams/ocp10721.json"
    When I run the :create client command with:
      | filename | ocp10721.json |
    Then the step should succeed
    Given I wait up to 15 seconds for the steps to pass:
    """
    When I run the :get client command with:
      | resource | imagestreamtags |
    Then the step should succeed
    And the output should not contain:
      | aosqeruby:3.3 |
    """

  # @author wjiang@redhat.com
  # @case_id OCP-11760
  Scenario: Import Image when spec.DockerImageRepository not defined
    Given I have a project
    Given I obtain test data file "image-streams/ocp11760.json"
    When I run the :create client command with:
      | filename | ocp11760.json |
    Then the step should succeed
    Given I wait up to 15 seconds for the steps to pass:
    """
    When I run the :get client command with:
      | resource | imagestreamtags |
    Then the step should succeed
    And the output should contain:
      | aosqeruby:3.3 |
    And the output should not contain:
      | aosqeruby:latest |
    """

  # @author wjiang@redhat.com
  # @case_id OCP-12052
  @smoke
  Scenario: Import image when spec.DockerImageRepository with some tags defined when Kind==DockerImage
    Given I have a project
    Given I obtain test data file "image-streams/ocp12052.json"
    When I run the :create client command with:
      | filename | ocp12052.json |
    Then the step should succeed
    Given I wait up to 15 seconds for the steps to pass:
    """
    When I run the :get client command with:
      | resource | imagestreamtags |
    Then the step should succeed
    And the output should contain:
      | aosqeruby:3.3 |
    """

  # @author xiaocwan@redhat.com
  # @case_id OCP-11089
  Scenario: Tags should be added to ImageStream if image repository is from an external docker registry
    Given I have a project
    Given I obtain test data file "image-streams/external.json"
    When I run the :create client command with:
      | f | external.json |
    Then the step should succeed
    And I wait for the steps to pass:
    ## istag will not show promtly as soon as is create, need wait for a few seconds
    """
    When I run the :get client command with:
      | resource | imageStreams |
      | o        | yaml         |
    Then the step should succeed
    And the output should match:
      | tag:\\s+None    |
      | tag:\\s+latest  |
      | tag:\\s+busybox |
    """

  # @author geliu@redhat.com
  # @case_id OCP-12765
  Scenario: Allow imagestream request deployment config triggers by different mode('TagreferencePolicy':source/local)
    Given I have a project
    When I run the :tag client command with:
      | source_type | docker                       |
      | source      | openshift/deployment-example |
      | dest        | deployment-example:latest    |
    Then the step should succeed
    And the "deployment-example" image stream becomes ready
    When I run the :new_app_as_dc client command with:
      | image_stream | deployment-example:latest   |
    Then the output should match:
      | .*[Ss]uccess.*|
    When I run the :get client command with:
      | resource        | imagestreams |
    Then the output should match:
      | .*deployment-example.* |
    When I run the :get client command with:
      | resource_name   | deployment-example |
      | resource        | dc                 |
      | o               | yaml               |
    Then the output should match:
      | openshift/deployment-example@sha256 |
    When I run the :delete client command with:
      | object_type | dc |
      | all         |    |
    Then the step should succeed
    When I run the :delete client command with:
      | object_type | is |
      | all         |    |
    Then the step should succeed
    When I run the :delete client command with:
      | object_type | svc |
      | all         |     |
    Then the step should succeed
    When I run the :tag client command with:
      | source_type      | docker                       |
      | source           | openshift/deployment-example |
      | dest             | deployment-example:latest    |
      | reference_policy | local                        |
    Then the step should succeed
    And the "deployment-example" image stream becomes ready
    When I run the :new_app_as_dc client command with:
      | image_stream | deployment-example:latest   |
    Then the output should match:
      | .*[Ss]uccess.* |
    When I run the :get client command with:
      | resource        | imagestreams |
    Then the output should match:
      | .*deployment-example.* |
    When I run the :get client command with:
      | resource_name   | deployment-example |
      | resource        | dc                 |
      | o               | yaml               |
    Then the output should match:
      | <%= project.name %>\/deployment-example@sha256 |

  # @author geliu@redhat.com
  # @case_id OCP-12766
  Scenario: Allow imagestream request build config triggers by different mode('TagreferencePolicy':source/local)
    Given I have a project
    When I run the :import_image client command with:
      | from       | centos/ruby-25-centos7 |
      | confirm    | true                   |
      | image_name | ruby-25-centos7:latest |
    Then the step should succeed
    When I run the :new_build client command with:
      | image_stream | ruby-25-centos7                       |
      | code         | https://github.com/sclorg/ruby-ex.git |
    Then the step should succeed
    When I run the :get client command with:
      | resource_name   | ruby-ex |
      | resource        | bc      |
      | o               | yaml    |
    Then the expression should be true> @result[:parsed]['spec']['triggers'][3]['imageChange']['lastTriggeredImageID'].include? 'centos/ruby-25-centos7'
    When I run the :delete client command with:
      | object_type | bc |
      | all         |    |
    Then the step should succeed
    When I run the :delete client command with:
      | object_type | is |
      | all         |    |
    Then the step should succeed
    When I run the :import_image client command with:
      | from            | centos/ruby-25-centos7 |
      | confirm         | true                   |
      | image_name      | ruby-25-centos7:latest |
      | reference-policy| local                  |
    Then the step should succeed
    When I run the :new_build client command with:
      | image_stream | ruby-25-centos7                       |
      | code         | https://github.com/sclorg/ruby-ex.git |
    Then the step should succeed
    When I run the :get client command with:
      | resource_name   | ruby-ex |
      | resource        | bc      |
      | o               | yaml    |
    Then the expression should be true> @result[:parsed]['spec']['triggers'][3]['imageChange']['lastTriggeredImageID'].include? '<%= project.name %>/ruby-25-centos7'

