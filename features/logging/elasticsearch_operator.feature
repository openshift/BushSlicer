@clusterlogging
Feature: elasticsearch-operator related tests

  # @author qitang@redhat.com
  # @case_id OCP-21332
  @admin
  @destructive
  @commonlogging
  Scenario: ServiceMonitor Object for Elasticsearch is deployed along with the Elasticsearch cluster
    Given I wait for the "monitor-elasticsearch-cluster" service_monitor to appear
    And the expression should be true> service_monitor('monitor-elasticsearch-cluster').service_monitor_endpoint_spec(server_name: "elasticsearch-metrics.openshift-logging.svc").port == "elasticsearch"
    And the expression should be true> service_monitor('monitor-elasticsearch-cluster').service_monitor_endpoint_spec(server_name: "elasticsearch-metrics.openshift-logging.svc").path == "/_prometheus/metrics"
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | _prometheus/metrics |
      | op           | GET                 |
    Then the step should succeed
    And the output should contain:
      | es_cluster_nodes_number          |
      | es_cluster_shards_active_percent |
    Given I wait up to 360 seconds for the steps to pass:
    """
    When I perform the GET prometheus rest client with:
      | path  | /api/v1/query?          |
      | query | es_cluster_nodes_number |
    Then the step should succeed
    And the expression should be true>  @result[:parsed]['data']['result'][0]['value']
    """

  # @author qitang@redhat.com
  @admin
  @destructive
  Scenario Outline: elasticsearch alerting rules test: ElasticsearchClusterNotHealthy
    Given I obtain test data file "logging/clusterlogging/example.yaml"
    Given I create clusterlogging instance with:
      | remove_logging_pods | true         |
      | crd_yaml            | example.yaml |
    Then the step should succeed
    Given I wait for the "elasticsearch-prometheus-rules" prometheus_rule to appear
    And I wait for the "monitor-elasticsearch-cluster" service_monitor to appear
    When I run the :patch client command with:
      | resource      | clusterlogging                             |
      | resource_name | instance                                   |
      | p             | {"spec": {"managementState": "Unmanaged"}} |
      | type          | merge                                      |
    Then the step should succeed
    When I run the :patch client command with:
      | resource      | elasticsearch                              |
      | resource_name | elasticsearch                              |
      | p             | {"spec": {"managementState": "Unmanaged"}} |
      | type          | merge                                      |
    Then the step should succeed
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | _cluster/settings' -d '{"<cluster_setting>" : {"cluster.routing.allocation.enable" : "none"}} |
      | op           | PUT                                                                                           |
    Then the step should succeed
    And the output should contain:
      | "acknowledged":true |
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | test-index-001 |
      | op           | PUT            |
    Then the step should succeed
    And the output should contain:
      | "acknowledged":true |

    And I wait up to 360 seconds for the steps to pass:
    """
    When I perform the GET prometheus rest client with:
      | path  | /api/v1/query?                                     |
      | query | ALERTS{alertname="ElasticsearchClusterNotHealthy"} |
    Then the step should succeed
    And the output should match:
      | "alertstate":"pending\|firing" |
    """
    Examples:
      | cluster_setting |
      | transient       | # @case_id OCP-21530
      | persistent      | # @case_id OCP-30092

  # @author qitang@redhat.com
  # @case_id OCP-33883
  @admin
  @destructive
  @commonlogging
  Scenario: Additional essential metrics ES dashboard
    Given I switch to the first user
    And the first user is cluster-admin
    And I open admin console in a browser
    When I run the :goto_monitoring_db_elasticsearch web action
    Then the step should succeed
    And I wait up to 300 seconds for the steps to pass:
    """
    When I perform the :check_monitoring_dashboard_card web action with:
      | card_name | Cluster status |
    Then the step should succeed
    """
    Given evaluation of `["Cluster nodes", "Cluster data nodes", "Cluster pending tasks", "Cluster active shards", "Cluster non-active shards", "Number of segments", "Memory used by segments", "ThreadPool tasks", "CPU % usage", "Memory usage", "Disk space % used", "Documents indexing rate", "Indexing latency", "Search rate", "Search latency", "Documents count (with replicas)", "Documents deleting rate", "Documents merging rate", "Field data memory size", "Field data evictions", "Query cache size", "Query cache evictions", "Query cache hits", "Query cache misses", "Indexing throttling", "Merging throttling", "Heap used", "GC count", "GC time"]` is stored in the :cards clipboard
    And I repeat the following steps for each :card in cb.cards:
    """
    When I perform the :check_monitoring_dashboard_card web action with:
      | card_name | #{cb.card} |
    Then the step should succeed
    """
