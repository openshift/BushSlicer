@clusterlogging
Feature: Elasticsearch related tests

  # @author qitang@redhat.com
  # @case_id OCP-22050
  @admin
  @destructive
  Scenario: Elasticsearch using dynamic volumes
    Given default storageclass is stored in the :default_sc clipboard
    Given I obtain test data file "logging/clusterlogging/clusterlogging-storage-template.yaml"
    Given I create clusterlogging instance with:
      | remove_logging_pods | true                                 |
      | crd_yaml            | clusterlogging-storage-template.yaml |
      | storage_class       | <%= cb.default_sc.name %>            |
      | storage_size        | 10Gi                                 |
    Then the step should succeed
    And the expression should be true> cluster_logging('instance').logstore_storage_class_name == cb.default_sc.name
    And the expression should be true> elasticsearch('elasticsearch').nodes[0]['storage']['storageClassName'] == cb.default_sc.name
    Given I wait up to 300 seconds for the steps to pass:
    """
    Given evaluation of `elasticsearch('elasticsearch').nodes[0]['genUUID']` is stored in the :gen_uuid clipboard
    And the expression should be true> cb.gen_uuid != nil
    """
    Given a pod becomes ready with labels:
      | component=elasticsearch |
    And the expression should be true> pod.volume_claims.first.name.include? "elasticsearch-elasticsearch-cdm" and pod.volume_claims.first.name.include? cb.gen_uuid
    And the expression should be true> persistent_volume_claim(pod.volume_claims.first.name).exists?
    When I execute on the pod:
      | ls | /elasticsearch/persistent/elasticsearch/logs |
    Then the step should succeed
    And the output should contain:
      | elasticsearch.log                        |
      | elasticsearch_deprecation.log            |
      | elasticsearch_index_indexing_slowlog.log |
      | elasticsearch_index_search_slowlog.log   |

  # @author qitang@redhat.com
  # @case_id OCP-30776
  @admin
  @destructive
  @commonlogging
  Scenario: Elasticsearch6 new data modle indices
    Given I switch to the first user
    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    Given a pod becomes ready with labels:
      | run=centos-logtest,test=centos-logtest |
    #When I login to kibana logging web console
    #Then the step should succeed
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | _cat/indices?format=JSON |
      | op           | GET                      |
    Then the step should succeed
    And the output should contain:
      | app-00    |
      | infra-00  |
      | .kibana_  |
      | .security |

  # @author qitang@redhat.com
  # @case_id OCP-28140
  @admin
  @destructive
  Scenario: Elasticsearch retention policy testing
    Given I switch to the first user
    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    Given a pod becomes ready with labels:
      | run=centos-logtest,test=centos-logtest |
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given I obtain test data file "logging/clusterlogging/index_management_test.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true                       |
      | crd_yaml            | index_management_test.yaml |
    Then the step should succeed
    Given I wait for the "infra" index to appear in the ES pod with labels "es-node-master=true"
    And I wait for the "app" index to appear in the ES pod with labels "es-node-master=true"
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | _cat/indices?format=JSON |
      | op           | GET                      |
    Then the step should succeed
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "app"}.map {|x| x["index"]}` is stored in the :app_indices clipboard
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "infra"}.map {|x| x["index"]}` is stored in the :infra_indices clipboard
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "audit"}.map {|x| x["index"]}` is stored in the :audit_indices clipboard

    Given I successfully merge patch resource "elasticsearch/elasticsearch" with:
      | {"spec": {"managementState": "Unmanaged"}} |
    And the expression should be true> elasticsearch("elasticsearch").management_state == "Unmanaged"
    Given evaluation of `["elasticsearch-im-app", "elasticsearch-im-audit", "elasticsearch-im-infra"]` is stored in the :cj_names clipboard
    And I repeat the following steps for each :cj_name in cb.cj_names:
    """
    Given I successfully merge patch resource "cronjob/#{cb.cj_name}" with:
      | {"spec": {"schedule": "*/3 * * * *"}} |
    And the expression should be true> cron_job('#{cb.cj_name}').schedule(cached: false) == "*/3 * * * *"
    """
    When I check the cronjob status
    Then the step should succeed
    # check if there has new index created and check if the old index could be deleted or not
    # !(cb.new_app_indices - cb.app_indices).empty? ensures there has new index
    # !(cb.app_indices - cb.new_app_indices).empty? ensures some old indices can be deleted
    Given I wait up to 660 seconds for the steps to pass:
    """
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | _cat/indices?format=JSON |
      | op           | GET                      |
    Then the step should succeed
    Given evaluation of `@result[:parsed].select {|e| e['index'].start_with? "app"}.map {|x| x["index"]}` is stored in the :new_app_indices clipboard
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "infra"}.map {|x| x["index"]}` is stored in the :new_infra_indices clipboard
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "audit"}.map {|x| x["index"]}` is stored in the :new_audit_indices clipboard
    Then the expression should be true> !(cb.new_app_indices - cb.app_indices).empty? && !(cb.app_indices - cb.new_app_indices).empty?
    And the expression should be true> !(cb.new_infra_indices - cb.infra_indices).empty? && !(cb.infra_indices - cb.new_infra_indices).empty?
    And the expression should be true> !(cb.new_audit_indices - cb.audit_indices).empty? && !(cb.audit_indices - cb.new_audit_indices).empty?
    """
