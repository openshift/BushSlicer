@clusterlogging
Feature: cluster log forwarder features

  # @author qitang@redhat.com
  # @case_id OCP-25989
  @admin
  @destructive
  @commonlogging
  Scenario: ClusterLogForwarder `default` behavior testing
    Given the master version >= "4.6"
    # create project to generate logs
    Given I switch to the first user
    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    # check logs in ES
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given I wait for the "app" index to appear in the ES pod with labels "es-node-master=true"
    And I wait for the project "<%= cb.proj.name %>" logs to appear in the ES pod
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > 0
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | audit*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] = 0
    # forward logs to fluentd server
    Given fluentd receiver is deployed as secure with mTLS_share enabled in the "openshift-logging" project
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    Given I obtain test data file "logging/clusterlogforwarder/fluentd/secure/clusterlogforwarder.yaml"
    When I process and create:
      | f | clusterlogforwarder.yaml |
    Then the step should succeed
    And I wait for the "instance" cluster_log_forwarder to appear
    Given 10 seconds have passed
    And <%= daemon_set('fluentd').replica_counters[:desired] %> pods become ready with labels:
      | logging-infra=fluentd |
    Given I wait up to 300 seconds for the steps to pass:
    """
    And I execute on the "<%= cb.log_receiver.name %>" pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | app.log             |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """
    # the ES should not receive new logs(may have some cache in the fluentd)

    Given I wait up to 600 seconds for the steps to pass:
    """
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_count?pretty  |
      | op           | GET                 |
    Then the step should succeed
    And evaluation of `@result[:parsed]['count']` is stored in the :app_log_count_1 clipboard
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And evaluation of `@result[:parsed]['count']` is stored in the :infra_log_count_1 clipboard
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | audit*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] = 0
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_count?pretty  |
      | op           | GET                 |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] == cb.app_log_count_1
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] == cb.infra_log_count_1
    """

    # forward logs to fluentd and ES
    Given I obtain test data file "logging/clusterlogforwarder/multiple_receiver/clusterlogforwarder.yaml"
    When I run the :apply client command with:
      | f | clusterlogforwarder.yaml |
    Then the step should succeed
    Given 10 seconds have passed
    And <%= daemon_set('fluentd').replica_counters[:desired] %> pods become ready with labels:
      | logging-infra=fluentd |

    Given I wait up to 300 seconds for the steps to pass:
    """
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_count?pretty  |
      | op           | GET                 |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > cb.app_log_count_1
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > cb.infra_log_count_1
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | audit*/_count?pretty  |
      | op           | GET                   |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > 0
    """
    When I run the :delete client command with:
      | object_type       | pod                         |
      | object_name_or_id | <%= cb.log_receiver.name %> |
    Then the step should succeed
    And a pod becomes ready with labels:
      | logging-infra=fluentdserver |
    Given I wait up to 300 seconds for the steps to pass:
    """
    And I execute on the pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | app.log             |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """

  # @author qitang@redhat.com
  # @case_id OCP-29843
  @admin
  @destructive
  Scenario: ClusterLogForwarder: Forward logs to fluentd as insecure
    Given I switch to the first user
    And I have a project
    And evaluation of `project` is stored in the :fluentd_proj clipboard
    Given fluentd receiver is deployed as insecure in the "<%= cb.fluentd_proj.name %>" project

    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed

    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    And I obtain test data file "logging/clusterlogforwarder/fluentd/insecure/clusterlogforwarder.yaml"
    When I process and create:
      | f | clusterlogforwarder.yaml |
      | p | URL=udp://fluentdserver.<%= cb.fluentd_proj.name %>.svc:24224 |
    Then the step should succeed
    And I wait for the "instance" cluster_log_forwarder to appear

    Given I obtain test data file "logging/clusterlogging/fluentd_only.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true              |
      | crd_yaml            | fluentd_only.yaml |
    Then the step should succeed

    Given I use the "<%= cb.fluentd_proj.name %>" project
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the "<%= cb.log_receiver.name %>" pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | app.log             |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """

  # @author qitang@redhat.com
  @admin
  @destructive
  Scenario Outline: ClusterLogForwarder: Forward logs to fluentd as secure
    Given I switch to the first user
    And I have a project
    And evaluation of `project` is stored in the :fluentd_proj clipboard
    Given fluentd receiver is deployed as secure with <auth_type> enabled in the "<%= cb.fluentd_proj.name %>" project

    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed

    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    And I obtain test data file "logging/clusterlogforwarder/fluentd/secure/clusterlogforwarder.yaml"
    When I process and create:
      | f | clusterlogforwarder.yaml |
      | p | URL=tcp://fluentdserver.<%= cb.fluentd_proj.name %>.svc:24224 |
    Then the step should succeed
    And I wait for the "instance" cluster_log_forwarder to appear

    Given I obtain test data file "logging/clusterlogging/fluentd_only.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true              |
      | crd_yaml            | fluentd_only.yaml |
    Then the step should succeed

    Given I use the "<%= cb.fluentd_proj.name %>" project
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the "<%= cb.log_receiver.name %>" pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | app.log             |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """
    Examples:
      | auth_type         |
      | mTLS_share        | # @case_id OCP-29844
      | mTLS              | # @case_id OCP-39041
      | server_auth       | # @case_id OCP-39042
      | server_auth_share | # @case_id OCP-39043

  # @author qitang@redhat.com
  @admin
  @destructive
  Scenario Outline: Forward logs with tags
    Given I switch to the first user
    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed

    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given I obtain test data file "logging/clusterlogforwarder/<file>"
    And admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    When I run the :create client command with:
      | f | <file> |
    Then the step should succeed
    And I wait for the "instance" cluster_log_forwarder to appear
    Given I obtain test data file "logging/clusterlogging/example_indexmanagement.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true                         |
      | crd_yaml            | example_indexmanagement.yaml |
    Then the step should succeed
    Given I wait for the "app" index to appear in the ES pod with labels "es-node-master=true"
    And I wait for the project "<%= cb.proj.name %>" logs to appear in the ES pod
    And I wait for the "audit" index to appear in the ES pod
    And I wait up to 300 seconds for the steps to pass:
    """
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_search?format=JSON' -d '{"size": 2, "sort": [{"@timestamp": {"order":"desc"}}]} |
      | op           | GET                 |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['hits']['hits'][0]['_source']['openshift']['labels'] == cluster_log_forwarder('instance').output_labels(name: '<app_pipeline_name>')
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_search?format=JSON' -d '{"size": 2, "sort": [{"@timestamp": {"order":"desc"}}], "query": {"exists": {"field": "systemd"}}} |
      | op           | GET                 |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['hits']['hits'][0]['_source']['openshift']['labels'] == cluster_log_forwarder('instance').output_labels(name: '<infra_pipeline_name>')
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | infra*/_search?format=JSON' -d '{"size": 2, "sort": [{"@timestamp": {"order":"desc"}}], "query": {"regexp": {"kubernetes.namespace_name": "openshift@"}}} |
      | op           | GET                 |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['hits']['hits'][0]['_source']['openshift']['labels'] == cluster_log_forwarder('instance').output_labels(name: '<infra_pipeline_name>')
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | audit*/_search?format=JSON' -d '{"size": 2, "sort": [{"@timestamp": {"order":"desc"}}]} |
      | op           | GET                 |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['hits']['hits'][0]['_source']['openshift']['labels'] == cluster_log_forwarder('instance').output_labels(name: '<audit_pipeline_name>')
    """

    Examples:
      | file                                 | app_pipeline_name     | infra_pipeline_name   | audit_pipeline_name   |
      | clf-forward-with-same-tag.yaml       | forward-to-default-es | forward-to-default-es | forward-to-default-es | # @case_id OCP-33750
      | clf-forward-with-different-tags.yaml | forward-app-logs      | forward-infra-logs    | forward-audit-logs    | # @case_id OCP-33893

  # @author gkarager@redhat.com
  # @case_id OCP-33627
  @admin
  @destructive
  Scenario: Forward logs to remote-syslog - config error
    Given the master version >= "4.6"
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project

    Given rsyslog receiver is deployed as insecure in the "openshift-logging" project
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    Given I obtain test data file "logging/clusterlogforwarder/rsyslog/rsys_clf_invalid_values.yaml"
    When I run the :create client command with:
      | f | rsys_clf_invalid_values.yaml |
    Then the step should fail

  # @author gkarager@redhat.com
  @admin
  @destructive
  Scenario Outline: Forward logs to remote-syslog
    Given the master version >= "4.6"
    Given I switch to the first user
    And I have a project
    And evaluation of `project` is stored in the :syslog_proj clipboard
    Given rsyslog receiver is deployed as insecure in the "<%= cb.syslog_proj.name %>" project

    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed

    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    Given I obtain test data file "logging/clusterlogforwarder/rsyslog/<file>"
    When I process and create:
      | f | <file> |
      | p | URL=<protocol>://rsyslogserver.<%= cb.syslog_proj.name %>.svc:514 |
    Then the step should succeed
    And I wait for the "instance" cluster_log_forwarder to appear

    Given I obtain test data file "logging/clusterlogging/fluentd_only.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true              |
      | crd_yaml            | fluentd_only.yaml |
    Then the step should succeed
    Given I use the "<%= cb.syslog_proj.name %>" project
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the "<%= cb.log_receiver.name %>" pod:
      | ls | -l | /var/log/clf/ |
    Then the output should contain:
      | app-container.log   |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """

    Examples:
      | file                  | protocol |
      | rsys_clf_RFC3164.yaml | tls      | # @case_id OCP-32643
      | rsys_clf_RFC5424.yaml | tcp      | # @case_id OCP-32967
      | rsys_clf_default.yaml | udp      | # @case_id OCP-32864

  # @author anli@redhat.com
  # @case_id OCP-32697
  @admin
  @destructive
  Scenario: Forward logs to different kafka topics
    Given I switch to the first user
    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :kafka_project clipboard
    # The following step will create 4 topics(topic-logging-all,topic-logging-infra,topic-logging-app,topic-logging-audit)
    Given I deploy kafka in the "<%= cb.kafka_project.name %>" project via amqstream operator
    And I run the :extract client command with:
      | resource | secret/my-cluster-cluster-ca-cert  |
    Then the step should succeed
    Given I use the "openshift-logging" project
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    Given admin ensures "kafka-fluent" secret is deleted from the "openshift-logging" project after scenario
    When I run the :create_secret client command with:
      | secret_type | generic              |
      | name        | kafka-fluent         |
      | from_file   | ca-bundle.crt=ca.crt |
    Then the step should succeed
    Given I obtain test data file "logging/clusterlogforwarder/kafka/amq/13_ClusterLogForwarder_to_kafka_template.yaml"
    Given I obtain test data file "logging/clusterlogging/fluentd_only.yaml"
    # The following step will send logs to topic-logging-infra,topic-logging-app,topic-logging-audit
    When I process and create:
      | f | 13_ClusterLogForwarder_to_kafka_template.yaml |
      | p | AMQ_NAMESPACE=<%= cb.kafka_project.name %>    |
    Then the step should succeed
    When I create clusterlogging instance with:
      | remove_logging_pods | true              |
      | crd_yaml            | fluentd_only.yaml |
    Then the step should succeed
    Given I switch to the first user
    #Given I create the "xyz" consumer job to the "topic-logging-infra" kafka topic in the "<%= cb.kafka_project.name %>" project
    #When I get 2 logs from the "xyz" kafka consumer job in the "<%= cb.kafka_project.name %>" project
    #Then the step should succeed
    When I get records from the "topic-logging-infra" kafka topic in the "<%= cb.kafka_project.name %>" project
    Then the step should succeed
    When I get records from the "topic-logging-app" kafka topic in the "<%= cb.kafka_project.name %>" project
    Then the step should succeed
    When I get records from the "topic-logging-audit" kafka topic in the "<%= cb.kafka_project.name %>" project
    Then the step should succeed

  # @author gkarager@redhat.com
  # @case_id OCP-32628
  @admin
  @destructive
  Scenario: Fluentd continues to ship logs even when one of multiple destination is down
    # create project to generate logs
    Given I switch to the first user
    Given I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    And I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    # create fluentd and elasticsearch receiver
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    And fluentd receiver is deployed as insecure in the "openshift-logging" project
    And external elasticsearch server is deployed with:
      | version               | 6.8               |
      | scheme                | http              |
      | transport_ssl_enabled | false             |
      | project_name          | openshift-logging |
    # create clusterlogforwarder instace with multiple receiver
    Given admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    And I obtain test data file "logging/clusterlogforwarder/multiple_receiver/clf_fluent_es.yaml"
    When I process and create:
      | f | clf_fluent_es.yaml |
    Then the step should succeed
    And I wait for the "instance" cluster_log_forwarder to appear
    # create clusterlogging instance
    Given I obtain test data file "logging/clusterlogging/fluentd_only.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true              |
      | crd_yaml            | fluentd_only.yaml |
    Then the step should succeed
    #Check logs in fluentd server
    Given a pod becomes ready with labels:
      | component=fluentdserver |
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | app.log             |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """
    #Check logs in elasticsearch server
    Given a pod becomes ready with labels:
      | app=elasticsearch-server |
    And I wait up to 300 seconds for the steps to pass:
    """
    # check app logs
    When I execute on the pod:
      | curl | -sk | -XGET | http://localhost:9200/*/_count?format=JSON | -H | Content-Type: application/json | -d | {"query": {"match": {"kubernetes.namespace_name": "<%= cb.proj.name %>"}}} |
    Then the step should succeed
    And evaluation of `JSON.parse(@result[:stdout])['count']` is stored in the :app_log_count_1 clipboard
    And the expression should be true> cb.app_log_count_1 > 0

    # check journal logs
    When I execute on the pod:
      | curl | -sk | -XGET | http://localhost:9200/*/_count?format=JSON | -H | Content-Type: application/json | -d | {"query": {"exists": {"field": "systemd"}}} |
    Then the step should succeed
    And evaluation of `JSON.parse(@result[:stdout])['count']` is stored in the :journal_log_count_1 clipboard
    And the expression should be true> cb.journal_log_count_1 > 0

    # check logs in openshift* namespace
    When I execute on the pod:
      | curl | -sk | -XGET | http://localhost:9200/*/_count?format=JSON | -H | Content-Type: application/json | -d | {"query": {"regexp": {"kubernetes.namespace_name": "openshift@"}}} |
    Then the step should succeed
    And evaluation of `JSON.parse(@result[:stdout])['count']` is stored in the :openshift_log_count_1 clipboard
    And the expression should be true> cb.openshift_log_count_1 > 0

    # check audit logs
    When I execute on the pod:
      | curl | -sk | -XGET | http://localhost:9200/*/_count?format=JSON | -H | Content-Type: application/json | -d | {"query": {"exists": {"field": "auditID"}}} |
    Then the step should succeed
    And evaluation of `JSON.parse(@result[:stdout])['count']` is stored in the :audit_log_count_1 clipboard
    And the expression should be true> cb.audit_log_count_1 > 0
    """
    # delete fluentd server
    Given I ensure "fluentdserver" config_map is deleted from the "openshift-logging" project
    And I ensure "fluentdserver" deployment is deleted from the "openshift-logging" project
    And I ensure "fluentdserver" service is deleted from the "openshift-logging" project
    # create another project to generate logs
    Given I switch to the first user
    Given I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj1 clipboard
    And I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    # Again check logs in elasticsearch server
    Given I switch to cluster admin pseudo user
    Given I use the "openshift-logging" project
    And a pod becomes ready with labels:
      | app=elasticsearch-server |
    And I wait up to 300 seconds for the steps to pass:
    """
    # check app logs
    When I execute on the pod:
      | curl | -sk | -XGET | http://localhost:9200/*/_count?format=JSON | -H | Content-Type: application/json | -d | {"query": {"match": {"kubernetes.namespace_name": "<%= cb.proj1.name %>"}}} |
    Then the step should succeed
    And evaluation of `JSON.parse(@result[:stdout])['count']` is stored in the :app_log_count_2 clipboard
    And the expression should be true> cb.app_log_count_2 > 0
    """

  # @author kbharti@redhat.com
  # @case_id OCP-39786
  @admin
  @destructive
  Scenario: Send logs to both external fluentd and internalES
    #Creating secure fluentd receiver
    Given I switch to cluster admin pseudo user
    Given fluentd receiver is deployed as secure with server_auth_share enabled in the "openshift-logging" project
    # Creating app
    Given I switch to the first user
    And I create a project with non-leading digit name
    And evaluation of `project` is stored in the :proj clipboard
    And I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed
    #Creating secure secret and ConfigMap
    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given admin ensures "secure-forward" config_map is deleted from the "openshift-logging" project after scenario
    Given admin ensures "secure-forward" secret is deleted from the "openshift-logging" project after scenario
    Given I run the :create_secret client command with:
      | name         | secure-forward           |
      | secret_type  | generic                  |
      | from_file    | ca-bundle.crt=ca.crt     |
      | n            | openshift-logging        |
    Then the step should succeed
    Given I obtain test data file "logging/clusterlogforwarder/fluentd/secure/secure-forward-cm.yaml"
    Given I run the :create client command with:
      | f | secure-forward-cm.yaml |
    Then the step should succeed
    And I wait for the "secure-forward" config_map to appear
    # Creating Cluster Logging Instance
    Given I obtain test data file "logging/clusterlogging/example_indexmanagement.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true                         |
      | crd_yaml            | example_indexmanagement.yaml |
    Then the step should succeed
    # Check logs in fluentd receiver
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the "<%= cb.log_receiver.name %>" pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | app.log             |
      | audit.log           |
      | infra.log           |
      | infra-container.log |
    """
    # Check logs in ES server
    Given I use the "openshift-logging" project
    When I perform the HTTP request on the ES pod with labels "es-node-master=true":
      | relative_url | app*/_count?format=JSON' -d '{"query": {"match": {"kubernetes.namespace_name": "<%= cb.proj.name %>"}}} |
      | op           | GET                     |
    Then the step should succeed
    And the expression should be true> @result[:parsed]['count'] > 0

  # @author qitang@redhat.com
  # @case_id OCP-30851
  @admin
  @destructive
  Scenario: Forward logs to mulitple external log aggregator
    Given I switch to the first user
    And I have a project
    And evaluation of `project` is stored in the :proj clipboard
    Given I obtain test data file "logging/loggen/container_json_log_template.json"
    When I run the :new_app client command with:
      | file | container_json_log_template.json |
    Then the step should succeed

    Given I create a project with non-leading digit name
    And evaluation of `project` is stored in the :receiver_proj clipboard
    Given fluentd receiver is deployed as secure with mTLS_share enabled in the "<%= cb.receiver_proj.name %>" project
    And rsyslog receiver is deployed as insecure in the "<%= cb.receiver_proj.name %>" project
    And external elasticsearch server is deployed with:
      | version               | 6.8                          |
      | scheme                | http                         |
      | transport_ssl_enabled | false                        |
      | project_name          | <%= cb.receiver_proj.name %> |
    #deploy kafka
    Given I deploy kafka in the "<%= cb.receiver_proj.name %>" project via amqstream operator

    Given I switch to cluster admin pseudo user
    And I use the "openshift-logging" project
    Given I obtain test data file "logging/clusterlogforwarder/clf-multiple-external-logstore-template.yaml"
    And admin ensures "instance" cluster_log_forwarder is deleted from the "openshift-logging" project after scenario
    When I process and create:
      | f | clf-multiple-external-logstore-template.yaml                                        |
      | p | FLUENTD_URL=udp://fluentdserver.<%= cb.receiver_proj.name %>.svc:24224              |
      | p | SYSLOG_URL=tcp://rsyslogserver.<%= cb.receiver_proj.name %>.svc:514                 |
      | p | ELASTICSEARCH_URL=http://elasticsearch-server.<%= cb.receiver_proj.name %>.svc:9200 |
      | p | AMQ_NAMESPACE=<%= cb.receiver_proj.name %>                                          |
    Then the step should succeed
    Given I obtain test data file "logging/clusterlogging/fluentd_only.yaml"
    When I create clusterlogging instance with:
      | remove_logging_pods | true              |
      | crd_yaml            | fluentd_only.yaml |
    Then the step should succeed
    #check data in fluentd server
    Given I use the "<%= cb.receiver_proj.name %>" project
    And a pod becomes ready with labels:
      | component=fluentdserver |
    Given I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the pod:
      | ls | -l | /fluentd/log |
    Then the output should contain:
      | infra.log           |
      | infra-container.log |
    And the output should not contain:
      | audit.log |
      | app.log   |
    """
    When I execute on the pod:
      | tail | -n | 1 | /fluentd/log/infra.log |
    Then the step should succeed
    And the output should contain:
      | "openshift":{"labels":{"logging":"infra-logs"}} |
    When I execute on the pod:
      | tail | -n | 1 | /fluentd/log/infra-container.log |
    Then the step should succeed
    And the output should contain:
      | "openshift":{"labels":{"logging":"infra-logs"}} |
    # check data in rsyslog server
    Given a pod becomes ready with labels:
      | component=rsyslogserver |
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the pod:
      | ls | -l | /var/log/clf/ |
    Then the output should contain:
      | audit.log |
    And the output should not contain:
      | app-container.log   |
      | infra.log           |
      | infra-container.log |
    """
    When I execute on the pod:
      | tail | -n | 1 | /var/log/clf/audit.log |
    Then the step should succeed
    And the output should contain:
      | openshift:{"labels"=>{"logging"=>"audit-logs"}} |
    # check data in external ES
    Given a pod becomes ready with labels:
      | app=elasticsearch-server |
    # check app logs
    And I wait up to 300 seconds for the steps to pass:
    """
    When I execute on the pod:
      | curl | -sk | -XGET | http://localhost:9200/_cat/indices?format=JSON |
    Then the step should succeed
    And the expression should be true> (JSON.parse(@result[:stdout]).find {|e| e['index'].start_with? "app"}) != nil
    And the expression should be true> (JSON.parse(@result[:stdout]).find {|e| e['index'].start_with? "infra"}).nil?
    And the expression should be true> (JSON.parse(@result[:stdout]).find {|e| e['index'].start_with? "audit"}).nil?
    When I execute on the pod:
      | curl | -s | -XGET | -H | Content-Type: application/json | http://localhost:9200/app*/_search?format=JSON | -d | {"query": {"match": {"kubernetes.namespace_name": "<%= cb.proj.name %>"}}} |
    Then the step should succeed
    And the output should contain:
      | "openshift":{"labels":{"logging":"application-logs"}} |
    """

    #check data in kafka
    When I get records from the "topic-logging-infra" kafka topic in the "<%= cb.receiver_proj.name %>" project
    Then the step should succeed
    And the output should contain:
      | "openshift":{"labels":{"logging":"infra-logs"}} |
    When I get records from the "topic-logging-app" kafka topic in the "<%= cb.receiver_proj.name %>" project
    Then the step should succeed
    And the output should contain:
      | "openshift":{"labels":{"logging":"application-logs"}} |
    When I get records from the "topic-logging-audit" kafka topic in the "<%= cb.receiver_proj.name %>" project
    Then the step should succeed
    And the output should contain:
      | "openshift":{"labels":{"logging":"audit-logs"}} |
