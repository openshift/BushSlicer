Feature: Logging smoke test case

  # @author gkarager@redhat.com
  # @case_id OCP-37508
  @admin
  Scenario: One logging acceptance case for all cluster
    # Deploy cluster-logging operator via web console
    Given logging service is removed successfully
    Given cluster-logging channel name is stored in the :clo_channel clipboard
    And elasticsearch-operator channel name is stored in the :eo_channel clipboard
    Given elasticsearch-operator catalog source name is stored in the :eo_catsrc clipboard
    Given cluster-logging catalog source name is stored in the :clo_catsrc clipboard
    Given I switch to the first user
    Given the first user is cluster-admin
    And evaluation of `user.cached_tokens.first` is stored in the :user_token_1 clipboard
    Given I open admin console in a browser
    # subscribe cluster-logging-operator
    When I perform the :goto_operator_subscription_page web action with:
      | package_name     | cluster-logging      |
      | catalog_name     | <%= cb.clo_catsrc %> |
      | target_namespace | openshift-logging    |
    Then the step should succeed
    And I perform the :set_custom_channel_and_subscribe web action with:
      | update_channel    | <%= cb.clo_channel %> |
      | install_mode      | OwnNamespace          |
      | approval_strategy | Automatic             |
    Given cluster logging operator is ready
    # subscribe elasticsearch-operator
    When I perform the :goto_operator_subscription_page web action with:
      | package_name     | elasticsearch-operator     |
      | catalog_name     | <%= cb.eo_catsrc %>        |
      | target_namespace | openshift-operators-redhat |
    Then the step should succeed
    When I perform the :set_custom_channel_and_subscribe web action with:
      | update_channel    | <%= cb.eo_channel %> |
      | install_mode      | AllNamespace         |
      | approval_strategy | Automatic            |
    Then the step should succeed
    Given elasticsearch operator is ready in the "openshift-operators-redhat" namespace
    Then I use the "openshift-logging" project
    And default storageclass is stored in the :default_sc clipboard
    Given I obtain test data file "logging/clusterlogging/cl-storage-with-im-template.yaml"
    When I process and create:
      | f | cl-storage-with-im-template.yaml        |
      | p | STORAGE_CLASS=<%= cb.default_sc.name %> |
      | p | PVC_SIZE=10Gi                           |
      | p | ES_NODE_COUNT=1                         |
      | p | REDUNDANCY_POLICY=ZeroRedundancy        |
    Then the step should succeed
    And I wait until ES cluster is ready
    And I wait until kibana is ready
    And I wait until fluentd is ready

    # check the .security index is created after ES pods started
    Given I wait for the ".security" index to appear in the ES pod with labels "es-node-master=true"
    And the expression should be true> cb.index_data['docs.count'] > "0"
    # Console Dashboard
    When I run the :goto_monitoring_db_cluster_logging web action
    Then the step should succeed
    Given evaluation of `["Elastic Nodes", "Elastic Shards", "Elastic Documents", "Total Index Size on Disk", "Elastic Pending Tasks", "Elastic JVM GC time", "Elastic JVM GC Rate", "Elastic Query/Fetch Latency | Sum", "Elastic Query Rate | Top 5", "CPU", "Elastic JVM Heap Used", "Elasticsearch Disk Usage", "File Descriptors In Use", "FluentD emit count", "FluentD Buffer Availability", "Elastic rx bytes", "Elastic Index Failure Rate", "FluentD Output Error Rate"]` is stored in the :cards clipboard
    Given I wait up to 360 seconds for the steps to pass:
    """
    When I perform the :check_monitoring_dashboard_card web action with:
      | card_name | Elastic Cluster Status |
    Then the step should succeed
    """
    And I repeat the following steps for each :card in cb.cards:
    """
    When I perform the :check_monitoring_dashboard_card web action with:
      | card_name | #{cb.card} |
    Then the step should succeed
    """
    And I close the current browser
    # ES Metrics
    Given I wait for the "monitor-elasticsearch-cluster" service_monitor to appear
    And the expression should be true> service_monitor('monitor-elasticsearch-cluster').service_monitor_endpoint_spec(server_name: "elasticsearch-metrics.openshift-logging.svc").port == "elasticsearch"
    And the expression should be true> service_monitor('monitor-elasticsearch-cluster').service_monitor_endpoint_spec(server_name: "elasticsearch-metrics.openshift-logging.svc").path == "/_prometheus/metrics"
    Given I wait up to 360 seconds for the steps to pass:
    """
    When I perform the GET prometheus rest client with:
      | path  | /api/v1/query?          |
      | query | es_cluster_nodes_number |
    Then the step should succeed
    And the expression should be true>  @result[:parsed]['data']['result'][0]['value']
    """
    # Fluentd Metrics
    Given I use the "openshift-logging" project
    And I wait for the "fluentd" service_monitor to appear
    Given the expression should be true> service_monitor('fluentd').service_monitor_endpoint_spec(server_name: "fluentd.openshift-logging.svc").port == "metrics"
    And the expression should be true> service_monitor('fluentd').service_monitor_endpoint_spec(server_name: "fluentd.openshift-logging.svc").path == "/metrics"
    Given I wait up to 360 seconds for the steps to pass:
    """
    When I perform the GET prometheus rest client with:
      | path  | /api/v1/query?                            |
      | query | fluentd_output_status_buffer_queue_length |
    Then the step should succeed
    And the expression should be true>  @result[:parsed]['data']['result'][0]['value']
    """
    # Kibana Access
    Given I switch to the second user
    Given I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    And I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    Given a pod becomes ready with labels:
      | run=centos-logtest,test=centos-logtest |

    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given I wait for the "app" index to appear in the ES pod with labels "es-node-master=true"
    Given I wait for the "infra" index to appear in the ES pod with labels "es-node-master=true"
    And I wait for the project "<%= cb.proj.name %>" logs to appear in the ES pod

    Given I switch to the second user
    And evaluation of `user.cached_tokens.first` is stored in the :user_token_2 clipboard
    When I login to kibana logging web console
    Then the step should succeed
    And I close the current browser
    # Data Check
    # Authorization
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    # cluster-admin user
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_count?format=JSON |
      | op           | GET                       |
      | token        | <%= cb.user_token_1 %>    |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > 0
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_count?format=JSON |
      | op           | GET                     |
      | token        | <%= cb.user_token_1 %>  |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > 0
    # normal user
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_count?format=JSON' -d '{"query": {"match": {"kubernetes.namespace_name": "<%= cb.proj.name %>"}}} |
      | op           | GET                                                                                                     |
      | token        | <%= cb.user_token_2 %>                                                                                  |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > 0
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_count?format=JSON |
      | op           | GET                       |
      | token        | <%= cb.user_token_2 %>    |
    Then the step should succeed
    And the expression should be true> [401, 403].include? @result[:exitstatus]

    # Cronjob
    # check if the cronjobs could delete/rollover indices
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | _cat/indices?format=JSON |
      | op           | GET                      |
    Then the step should succeed
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "app"}.map {|x| x["index"]}` is stored in the :app_indices clipboard
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "infra"}.map {|x| x["index"]}` is stored in the :infra_indices clipboard
    And evaluation of `@result[:parsed].select {|e| e['index'].start_with? "audit"}.map {|x| x["index"]}` is stored in the :audit_indices clipboard

    Given I register clean-up steps:
    """
    Given I successfully merge patch resource "clusterlogging/instance" with:
      | {"spec": {"logStore": {"retentionPolicy": {"application": {"maxAge": "6h"}, "audit": {"maxAge": "1w"}, "infra": {"maxAge": "3h"}}}}} |
    And I successfully merge patch resource "elasticsearch/elasticsearch" with:
      | {"spec": {"managementState": "Managed"}} |
    """
    Given I successfully merge patch resource "clusterlogging/instance" with:
      | {"spec": {"logStore": {"retentionPolicy": {"application": {"maxAge": "6m"}, "audit": {"maxAge": "6m"}, "infra": {"maxAge": "6m"}}}}} |
    And I wait up to 60 seconds for the steps to pass:
    """
    Given the expression should be true> elasticsearch("elasticsearch").delete_min_age(cached: false, name: "app-policy") == "6m"
    And the expression should be true> elasticsearch("elasticsearch").delete_min_age(name: "infra-policy") == "6m"
    And the expression should be true> elasticsearch("elasticsearch").delete_min_age(name: "audit-policy") == "6m"
    """
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

    # check if there has new index created and check if the old index could be deleted or not
    # !(cb.new_app_indices - cb.app_indices).empty? ensures there has new index
    # !(cb.app_indices - cb.new_app_indices).empty? ensures some old indices can be deleted
    Given I check the cronjob status
    Then the step should succeed
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
