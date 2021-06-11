### logging related step definitions
# for 4.x we default logging installation is via OLM only

### none configurable, just use default parameters
Given /^logging service has been installed successfully$/ do
  ensure_destructive_tagged
  ensure_admin_tagged
  if env.version_cmp('4.5', user: user) < 0
    example_cr = "<%= BushSlicer::HOME %>/testdata/logging/clusterlogging/example.yaml"
  else
    example_cr = "<%= BushSlicer::HOME %>/testdata/logging/clusterlogging/example_indexmanagement.yaml"
  end
  step %Q/logging operators are installed successfully/
  step %Q/I create clusterlogging instance with:/, table(%{
    | remove_logging_pods | false         |
    | crd_yaml            | #{example_cr} |
  })
end

### configurable installation of logging
# available parameters are:
# :keep_installation: true/false   -- keep installation if true
# :crd_yaml  -- http url for logging crd yaml
# operator_group_yaml -- http url for operator group yaml
# :catsrc_logging_yaml] -- http url for catalogsourceconfig for logging
# :catsrc_elasticsearch_yaml] -- http url for catalogsourceconfig for ES
# :sub_logging_yaml  -- http url for logging subscription yaml
# :sub_elasticsearch_yaml -- http url for elastic search yaml
#
Given /^logging operators are installed successfully$/ do
  ensure_destructive_tagged
  ensure_admin_tagged
  step %Q/I switch to cluster admin pseudo user/
  step %Q/evaluation of `cluster_version('version').version` is stored in the :ocp_cluster_version clipboard/
  step %Q/cluster-logging channel name is stored in the :clo_channel clipboard/
  step %Q/elasticsearch-operator channel name is stored in the :eo_channel clipboard/

  unless project('openshift-operators-redhat').exists?
    eo_namespace_yaml = "#{BushSlicer::HOME}/testdata/logging/eleasticsearch/deploy_via_olm/01_eo-project.yaml"
    @result = admin.cli_exec(:create, f: eo_namespace_yaml)
    raise "Error creating namespace" unless @result[:success]
  end

  step %Q/I use the "openshift-operators-redhat" project/
  unless deployment('elasticsearch-operator').exists?
    unless operator_group('openshift-operators-redhat').exists?
      # Create operator group in `openshift-operators-redhat` namespace
      eo_operator_group_yaml ||= "#{BushSlicer::HOME}/testdata/logging/eleasticsearch/deploy_via_olm/02_eo-og.yaml"
      @result = admin.cli_exec(:create, f: eo_operator_group_yaml)
      raise "Error creating operatorgroup" unless @result[:success]
    end

    #TODO: start from logging 5.1, no need to create role and rolebing, these resources will be created by OLM operator
    unless role_binding('prometheus-k8s').exists?
      # create RBAC object in `openshift-operators-redhat` namespace
      operator_group_yaml ||= "#{BushSlicer::HOME}/testdata/logging/eleasticsearch/deploy_via_olm/03_eo-rbac.yaml"
      @result = admin.cli_exec(:create, f: operator_group_yaml)
      raise "Error creating rolebinding" unless @result[:success]
    end

    unless subscription('elasticsearch-operator').exists?
      step %Q/I use the "openshift-marketplace" project/
      # first check packagemanifest exists for elasticsearch-operator
      raise "Required packagemanifest 'elasticsearch-operator' no found!" unless package_manifest('elasticsearch-operator').exists?
      step %Q/elasticsearch-operator catalog source name is stored in the :eo_catsrc clipboard/
      step %Q/I use the "openshift-operators-redhat" project/
      if cb.ocp_cluster_version.include? "4.1."
        # create catalogsourceconfig and subscription for elasticsearch-operator
        catsrc_elasticsearch_yaml ||= "#{BushSlicer::HOME}/testdata/logging/eleasticsearch/deploy_via_olm/4.1/04_eo-csc.yaml"
        @result = admin.cli_exec(:create, f: catsrc_elasticsearch_yaml)
        raise "Error creating catalogsourceconfig for elasticsearch" unless @result[:success]
        sub_elasticsearch_yaml ||= "#{BushSlicer::HOME}/testdata/logging/eleasticsearch/deploy_via_olm/4.1/05_eo-sub.yaml"
        @result = admin.cli_exec(:create, f: sub_elasticsearch_yaml)
        raise "Error creating subscription for elasticsearch" unless @result[:success]
      else
        # create subscription in "openshift-operators-redhat" namespace:
        sub_elasticsearch_yaml ||= "#{BushSlicer::HOME}/testdata/logging/eleasticsearch/deploy_via_olm/4.2/eo-sub-template.yaml"
        step %Q/I process and create:/, table(%{
          | f | #{sub_elasticsearch_yaml} |
          | p | SOURCE=#{cb.eo_catsrc}    |
          | p | CHANNEL=#{cb.eo_channel}  |
        })
        raise "Error creating subscription for elasticsearch" unless @result[:success]
      end
    end
  end
  # check csv existense
  success = wait_for(300, interval: 10) {
    csv = subscription('elasticsearch-operator').current_csv
    !(csv.nil?) && cluster_service_version(csv).exists?
  }
  raise "CSV #{csv} isn't created" unless success
  step %Q/elasticsearch operator is ready/

  # Create namespace
  unless project('openshift-logging').exists?
    namespace_yaml = "#{BushSlicer::HOME}/testdata/logging/clusterlogging/deploy_clo_via_olm/01_clo_ns.yaml"
    @result = admin.cli_exec(:create, f: namespace_yaml)
    raise "Error creating namespace" unless @result[:success]
  end

  step %Q/I use the "openshift-logging" project/
  unless deployment('cluster-logging-operator').exists?
    unless operator_group('openshift-logging').exists?
      clo_operator_group_yaml ||= "#{BushSlicer::HOME}/testdata/logging/clusterlogging/deploy_clo_via_olm/02_clo_og.yaml"
      @result = admin.cli_exec(:create, f: clo_operator_group_yaml)
      raise "Error creating operatorgroup" unless @result[:success]
    end

    unless subscription('cluster-logging').exists?
      step %Q/I use the "openshift-marketplace" project/
      # first check packagemanifest exists for cluster-logging
      raise "Required packagemanifest 'cluster-logging' no found!" unless package_manifest('cluster-logging').exists?
      step %Q/cluster-logging catalog source name is stored in the :clo_catsrc clipboard/
      step %Q/I use the "openshift-logging" project/
      if cb.ocp_cluster_version.include? "4.1."
        # create catalogsourceconfig and subscription for cluster-logging-operator
        catsrc_logging_yaml ||= "#{BushSlicer::HOME}/testdata/logging/clusterlogging/deploy_clo_via_olm/4.1/03_clo_csc.yaml"
        @result = admin.cli_exec(:create, f: catsrc_logging_yaml)
        raise "Error creating catalogsourceconfig for cluster_logging" unless @result[:success]
        sub_logging_yaml ||= "#{BushSlicer::HOME}/testdata/logging/clusterlogging/deploy_clo_via_olm/4.1/04_clo_sub.yaml"
        @result = admin.cli_exec(:create, f: sub_logging_yaml)
        raise "Error creating subscription for cluster_logging" unless @result[:success]
      else
        # create subscription in `openshift-logging` namespace:
        sub_logging_yaml ||= "#{BushSlicer::HOME}/testdata/logging/clusterlogging/deploy_clo_via_olm/4.2/clo-sub-template.yaml"
        step %Q/I process and create:/, table(%{
          | f | #{sub_logging_yaml}       |
          | p | SOURCE=#{cb.clo_catsrc}   |
          | p | CHANNEL=#{cb.clo_channel} |
        })
        raise "Error creating subscription for cluster_logging" unless @result[:success]
      end
    end
  end
  # check csv existense
  success = wait_for(300, interval: 10) {
    csv = subscription('cluster-logging').current_csv
    !(csv.nil?) && cluster_service_version(csv).exists?
  }
  raise "CSV #{csv} isn't created" unless success
  step %Q/cluster logging operator is ready/
end

## To check cluserlogging is working correctly, we check all of the subcomponents' status
#  The list of components currently are: ["collection", "curation", "logStore",  "visualization"]
Given /^I wait for clusterlogging(?: named "(.+)")? to be functional in the#{OPT_QUOTED} project$/ do | logging_name, proj_name |
  ensure_admin_tagged
  cb.target_proj ||= 'openshift-logging'
  proj_name = cb.target_proj if proj_name.nil?
  org_proj_name = project.name
  logging_name ||= 'instance'

  step %Q/I switch to cluster admin pseudo user/
  step %Q/I use the "#{proj_name}" project/

  cb.cluster_logging ||= cluster_logging(logging_name)
  cl = cb.cluster_logging
  logger.info("### checking logging subcomponent status")

  # check elasticsearch subcomponent is ready
  logger.info("### checking logging subcomponent status: elasticsearch")
  step %Q/a pod becomes ready with labels:/, table(%{
    | component=elasticsearch |
  })
  cl.wait_until_es_is_ready

  # check log collector is ready.
  logger.info("### checking logging subcomponent status: log collector")
  step %Q/a pod becomes ready with labels:/, table(%{
    | component=fluentd |
  })
  cl.wait_until_fluentd_is_ready

  logger.info("### checking logging subcomponent status: kibana")
  step %Q/a pod becomes ready with labels:/, table(%{
    | component=kibana |
  })
  cl.wait_until_kibana_is_ready
  # check the cronjob curator.
  if env.version_lt('4.5', user: user)
    raise "Failed to find cronjob for curator" unless cron_job('curator').exists?
  end

  # check the cronjob index management
  if env.version_gt('4.4', user: user)
    cj_names = ["elasticsearch-im-app", "elasticsearch-im-audit", "elasticsearch-im-infra"]
    for cj_name in cj_names do
      raise "Failed to find cronjob for #{cj_name}" unless cron_job(cj_name).exists?
    end
  end
end

# to cleanup OLM installed clusterlogging
Given /^logging service is removed successfully$/ do
  ensure_admin_tagged
  # remove namespace
  clo_proj_name = "openshift-logging"
  step %Q/I switch to cluster admin pseudo user/
  if project(clo_proj_name).exists?
    @result = admin.cli_exec(:delete, object_type: 'project', object_name_or_id: clo_proj_name, n: clo_proj_name)
    raise "Unable to delete #{clo_proj_name}" unless @result[:success]
    step %Q/I wait for the resource "project" named "#{clo_proj_name}" to disappear/
  end
  eo_proj_name = "openshift-operators-redhat"
  if project(eo_proj_name).exists?
    @result = admin.cli_exec(:delete, object_type: 'project', object_name_or_id: eo_proj_name, n: eo_proj_name)
    raise "Unable to delete #{eo_proj_name}" unless @result[:success]
    step %Q/I wait for the resource "project" named "#{eo_proj_name}" to disappear/
  end

  # remove catalogsourceconfigs if ocp cluster version is 4.1
  step %Q/evaluation of `cluster_version('version').version` is stored in the :ocp_cluster_version clipboard/
  if cb.ocp_cluster_version.include? "4.1."
    csc_logging_name = "cluster-logging-operator"
    csc_elasticsearch_name = "elasticsearch"
    @result = admin.cli_exec(:delete, object_type: 'csc', object_name_or_id: csc_logging_name, n: 'openshift-marketplace')
    @result = admin.cli_exec(:delete, object_type: 'csc', object_name_or_id: csc_elasticsearch_name, n: 'openshift-marketplace')
    step %Q/I use the "openshift-marketplace" project/
    step %Q/I wait for the resource "csc" named "#{csc_logging_name}" to disappear/
    step %Q/I wait for the resource "csc" named "#{csc_elasticsearch_name}" to disappear/
  end
end

Given /^I wait until fluentd is ready$/ do
  step %Q/#{daemon_set('fluentd').replica_counters[:desired]} pods become ready with labels:/, table(%{
    | logging-infra=fluentd |
  })
end

Given /^I wait until ES cluster is ready$/ do
  step %Q/#{cluster_logging('instance').logstore_node_count.to_i} pods become ready with labels:/, table(%{
    | cluster-name=elasticsearch,component=elasticsearch |
  })
  cluster_logging('instance').wait_until_es_is_ready
end

Given /^I wait until kibana is ready$/ do
  step %Q/#{deployment('kibana').replica_counters[:desired]} pods become ready with labels:/, table(%{
    | component=kibana |
  })
end

Given /^cluster logging operator is ready$/ do
  ensure_admin_tagged
  project("openshift-logging")
  step %Q/a pod becomes ready with labels:/, table(%{
    | name=cluster-logging-operator |
  })
end

Given /^elasticsearch operator is ready(?: in the "(.+)" namespace)?$/ do | proj_name |
  ensure_admin_tagged
  if proj_name
    target_namespace = proj_name
  else
    target_namespace = "openshift-operators-redhat"
  end
  project(target_namespace)
  step %Q/a pod becomes ready with labels:/, table(%{
    | name=elasticsearch-operator |
  })
end

Given /^I create clusterlogging instance with:$/ do | table |
  opts = opts_array_to_hash(table.raw)
  ensure_admin_tagged
  step %Q/I switch to cluster admin pseudo user/
  step %Q/I use the "openshift-logging" project/
  crd_yaml = opts[:crd_yaml]
  storage_class = opts[:storage_class]
  storage_size = opts[:storage_size]
  es_node_count = opts[:es_node_count]
  redundancy_policy = opts[:redundancy_policy]
  if opts[:check_status].nil?
    check_status = 'true'
  else
    check_status = opts[:check_status]
  end

  if cluster_logging("instance").exists?
    step %Q/I delete the clusterlogging instance/
  end

  if !(storage_size.nil? && storage_class.nil?)
    process_opts=[
      ["f", "#{crd_yaml}"],
      ["n", "openshift-logging"]
    ]
    if !(storage_class.nil?)
      process_opts << ["p", "STORAGE_CLASS=#{storage_class}"]
    end
    if !(storage_size.nil?)
      process_opts << ["p", "PVC_SIZE=#{storage_size}"]
    end
    if !(es_node_count.nil?)
      process_opts << ["p", "ES_NODE_COUNT=#{es_node_count}"]
    end
    if !(redundancy_policy.nil?)
      process_opts << ["p", "REDUNDANCY_POLICY=#{redundancy_policy}"]
    end

    p_opts = opts_array_process(process_opts)
    p_opts << [:_stderr, :stderr]
    @result = admin.cli_exec(:process, p_opts)
    if @result[:success]
      @result = admin.cli_exec(:create, {f: "-", _stdin: @result[:stdout]})
    end
  else
    @result = admin.cli_exec(:create, f: crd_yaml, n: "openshift-logging")
  end

  raise "Unable to create clusterlogging instance" unless @result[:success]
  if opts[:remove_logging_pods] == 'true'
    teardown_add {
      step %Q/I delete the clusterlogging instance/
    }
  end
  step %Q/I wait for the "instance" clusterloggings to appear up to 300 seconds/
  if check_status == 'true'
    unless cluster_logging("instance").log_store_spec.nil?
      step %Q/I wait for the "elasticsearch" elasticsearches to appear up to 300 seconds/
      step %Q/I wait until ES cluster is ready/
    end
    unless  cluster_logging("instance").visualization_spec.nil?
      step %Q/I wait for the "kibana" deployment to appear up to 300 seconds/
      step %Q/I wait until kibana is ready/
    end
    unless cluster_logging('instance').collection_spec.nil?
      step %Q/I wait for the "fluentd" daemonset to appear up to 300 seconds/
      step %Q/I wait until fluentd is ready/
    end
  end
end

Given /^I delete the clusterlogging instance$/ do
  ensure_admin_tagged
  ensure_destructive_tagged
  step %Q/I switch to cluster admin pseudo user/
  step %Q/I use the "openshift-logging" project/
  if cluster_logging("instance").exists?
    @result = admin.cli_exec(:delete, object_type: 'clusterlogging', object_name_or_id: 'instance', n: 'openshift-logging')
    raise "Unable to delete instance" unless @result[:success]
  end
  step %Q/I wait for the resource "deployment" named "kibana" to disappear/
  step %Q/I wait for the resource "elasticsearch" named "elasticsearch" to disappear/
  step %Q/I wait for the resource "cronjob" named "curator" to disappear/
  step %Q/I wait for the resource "daemonset" named "fluentd" to disappear/
  step %Q/all existing pods die with labels:/, table(%{
    | component=elasticsearch |
  })
  step %Q/all existing pods die with labels:/, table(%{
    | component=kibana |
  })
  if BushSlicer::PersistentVolumeClaim.list(user: user, project: project).count > 0
    admin.cli_exec(:delete, object_type: 'pvc', l: 'logging-cluster=elasticsearch', n: 'openshift-logging')
  end
end

Given /^(cluster-logging|elasticsearch-operator) channel name is stored in the#{OPT_SYM} clipboard$/ do | packagemanifest, cb_name |
  cb_name = 'channel' unless cb_name
  logging_envs = env.logging_envs
  unless logging_envs.empty?
    case packagemanifest
    when "cluster-logging"
      envs = logging_envs[:clo]
    when "elasticsearch-operator"
      envs = logging_envs[:eo]
    end
  end
  project("openshift-marketplace")
  # check if the packagemanifest exist
  raise "Packagemanifest #{packagemanifest} doesn't exist" unless package_manifest(packagemanifest).exists?

  if (logging_envs.empty?) || (envs.nil?) || (envs[:channel].nil?)
    version = cluster_version('version').version.split('-')[0].split('.').take(2).join('.')
    case version
    when '4.1'
      cb[cb_name] = "preview"
    when '4.7'
      cb[cb_name] = "5.0"
    when '4.8'
      cb[cb_name] = "5.1"
    else
      cb[cb_name] = version
    end
  else
    cb[cb_name] = envs[:channel]
  end
end

Given /^(cluster-logging|elasticsearch-operator) catalog source name is stored in the#{OPT_SYM} clipboard$/ do | packagemanifest, cb_name |
  cb_name = 'source' unless cb_name
  logging_envs = env.logging_envs
  unless logging_envs.empty?
    case packagemanifest
    when "cluster-logging"
      envs = logging_envs[:clo]
    when "elasticsearch-operator"
      envs = logging_envs[:eo]
    end
  end
  project("openshift-marketplace")
  # check if the packagemanifest exist
  raise "Packagemanifest #{packagemanifest} doesn't exist" unless package_manifest(packagemanifest).exists?

  # get source name, if it's not set, use default source
  if (logging_envs.empty?) || (envs.nil?) || (envs[:catsrc].nil?)
    if catalog_source("qe-app-registry").exists?
      cb[cb_name] = "qe-app-registry"
    elsif catalog_source("redhat-operators").exists?
      cb[cb_name] = "redhat-operators"
    else
      cb[cb_name] = package_manifest(packagemanifest).catalog_source
    end
  else
    #raise "The specified catalog source doesn't exist" unless catalog_source(envs[:catsrc]).exists?
    cb[cb_name] = envs[:catsrc]
  end
end

Given /^the logging operators are redeployed after scenario$/ do
  _admin = admin
  teardown_add {
    step %Q/logging operators are installed successfully/
  }
end

# from logging 4.5, we don't have index project.$project-name.xxxxx, so we need other ways to check the project logs
# es_util --query=*/_count -d '{"query": {"match": {"kubernetes.namespace_name": "project-name"}}}'
# if count > 0, then the project logs are received
When /^I wait(?: (\d+) seconds)? for the project #{QUOTED} logs to appear in the ES pod(?: with labels #{QUOTED})?$/ do |seconds, project_name, pod_labels|

  if pod_labels
    labels = pod_labels
  else
    labels = "es-node-master=true"
  end
  step %Q/a pod becomes ready with labels:/, table(%{
    | #{labels} |
  })

  seconds = Integer(seconds) unless seconds.nil?
  seconds ||= 10 * 60
  success = wait_for(seconds) {
    step %Q/I perform the HTTP request on the ES pod with labels "#{labels}":/, table(%{
      | relative_url | */_count?format=JSON' -d '{"query": {"match": {"kubernetes.namespace_name": "#{project_name}"}}} |
      | op           | GET                                                                                              |
    })
    res = @result[:parsed]
    if res
      res['count'] > 0
    end
  }
  cb.doc_count = @result[:parsed]['count']
  raise "Can't find logs from project '#{project_name}' in #{seconds} seconds" unless success
end

Given /^logging eventrouter is installed in the cluster$/ do
  step %Q/admin ensures "event-reader" cluster_role is deleted after scenario/
  step %Q/admin ensures "event-reader-binding" cluster_role_binding is deleted after scenario/
  step %Q/admin ensures "eventrouter" service_account is deleted from the "openshift-logging" project after scenario/
  step %Q/admin ensures "eventrouter" config_map is deleted from the "openshift-logging" project after scenario/
  step %Q/admin ensures "eventrouter" deployment is deleted from the "openshift-logging" project after scenario/
  clo_csv_version = subscription("cluster-logging").current_csv(cached: false)
  if clo_csv_version.include? "cluster-logging"
    image_version = clo_csv_version.match(/cluster-logging\.(.*)/)[1].split('-')[0]
  else
    image_version = clo_csv_version.match(/clusterlogging\.(.*)/)[1].split('-')[0]
  end
  if image_version.start_with?("5")
    # from logging 5.0, the image name is changed to eventrouter-rhel8
    image_name = "eventrouter-rhel8"
  else
    image_name = "logging-eventrouter"
  end

  if image_content_source_policy('brew-registry').exists?
    registry = image_content_source_policy('brew-registry').mirror_repository[0]
    if image_version.start_with?("5")
      # from logging 5.0, the image namespace is changed to openshift-logging
      image = "#{registry}/rh-osbs/openshift-logging-#{image_name}:v#{image_version}"
    else
      image = "#{registry}/rh-osbs/openshift-ose-#{image_name}:v#{image_version}"
    end
  else
    # get image registry from CLO
    clo_image = deployment('cluster-logging-operator').container_spec(name: 'cluster-logging-operator').image
    registry = clo_image.split(/cluster-logging(.*)/)[0]
    image = "#{registry}#{image_name}:v#{image_version}"
  end
  step %Q/I process and create:/, table(%{
    | f | #{BushSlicer::HOME}/testdata/logging/eventrouter/internal_eventrouter.yaml |
    | p | IMAGE=#{image} |
  })
  step %Q/the step should succeed/
  step %Q/a pod becomes ready with labels:/, table(%{
    | component=eventrouter |
  })
end

Given /^I generate certs for the#{OPT_QUOTED} receiver(?: in the#{OPT_QUOTED} project)?$/ do | receiver_name, project_name |
  script_file = "#{BushSlicer::HOME}/testdata/logging/logforwarding/cert_generation.sh"
  project_name ||= "openshift-logging"
  #step %Q/I download a file from "#{script_file}"/
  shell_cmd = "sh #{script_file} $(pwd) #{project_name} #{receiver_name}"
  system(shell_cmd)
end

Given /^I create a pipeline secret with:$/ do | table |
  opts = opts_array_to_hash(table.raw)
  secret_name = opts[:secret_name]
  username = opts[:username]
  password = opts[:password]
  transport_ssl_enabled = opts[:transport_ssl_enabled]
  user_auth_enabled = opts[:user_auth_enabled]
  http_ssl_enabled = opts[:http_ssl_enabled]
  shared_key = opts[:shared_key]
  auth_type = opts[:auth_type]
  #require 'pry'
  #binding.pry
  unless tagged_upgrade? || secret_name.empty? || secret_name.nil?
    step %Q/admin ensures "#{secret_name}" secret is deleted from the "openshift-logging" project after scenario/
  end

  secret_keys = [
    ["name", "#{secret_name}"],
    ["secret_type", "generic"],
    ["n", "openshift-logging"]
  ]

  if transport_ssl_enabled == "true" || auth_type == "mTLS" || auth_type == "mTLS_share"
    secret_keys << ["from_file", "tls.key=logging-es.key"] << ["from_file", "tls.crt=logging-es.crt"] << ["from_file", "ca-bundle.crt=ca.crt"] << ["from_file", "ca.key=ca.key"]
  end

  if user_auth_enabled == "true"
    secret_keys << ["from_literal", "username=#{username}"] << ["from_literal", "password=#{password}"]
  end

  if http_ssl_enabled == "true" || auth_type == "server_auth" || auth_type == "server_auth_share"
    secret_keys << ["from_file", "ca-bundle.crt=ca.crt"] << ["from_file", "ca.key=ca.key"]
  end

  if auth_type == "mTLS_share" || auth_type == "server_auth_share"
    raise "No shared_key specified" unless !(shared_key.empty? || shared_key.nil?)
    secret_keys << ["from_literal", "shared_key=#{shared_key}"]
  end

  @result = admin.cli_exec(:create_secret, opts_array_process(secret_keys.uniq))
  raise "Unable to create secret #{secret_name}" unless @result[:success]
end

Given /^I create the resources for the receiver with:$/ do | table |
  org_user = user
  opts = opts_array_to_hash(table.raw)
  namespace = opts[:namespace]
  receiver_name = opts[:receiver_name]
  configmap_file = opts[:configmap_file]
  deployment_file = opts[:deployment_file]
  pod_label = opts[:pod_label]
  project(namespace)

  unless tagged_upgrade?
    step %Q/I ensure "#{receiver_name}" service_account is deleted from the "#{namespace}" project after scenario/
  end
  @result = user.cli_exec(:create_serviceaccount, serviceaccount_name: receiver_name, n: namespace)
  raise "Unable to create serviceaccout #{receiver_name}" unless @result[:success]

  if tagged_upgrade?
    step %Q/SCC "privileged" is added to the "system:serviceaccount:<%= project.name %>:#{receiver_name}" service account without teardown/
  else
    step %Q/SCC "privileged" is added to the "system:serviceaccount:<%= project.name %>:#{receiver_name}" service account/
    step %Q/I ensure "#{receiver_name}" config_map is deleted from the "#{namespace}" project after scenario/
    step %Q/I ensure "#{receiver_name}" deployment is deleted from the "#{namespace}" project after scenario/
    step %Q/I ensure "#{receiver_name}" service is deleted from the "#{namespace}" project after scenario/
  end

  files = [configmap_file, deployment_file]
  for file in files do
    @result = user.cli_exec(:create, f: file, n: namespace)
    raise "Unable to create resoure with #{file}" unless @result[:success]
  end
  if receiver_name == "rsyslogserver"
    svc_file = "#{BushSlicer::HOME}/testdata/logging/logforwarding/rsyslog/rsyslogserver_svc.yaml"
    @result = user.cli_exec(:create, f: svc_file, n: namespace)
    raise "Unable to expose the service for rsyslog server" unless @result[:success]
  else
    @result = user.cli_exec(:expose, name: receiver_name, resource: 'deployment', resource_name: receiver_name, namespace: namespace)
    raise "Unable to expose the service for #{receiver_name}" unless @result[:success]
  end
  step %Q/a pod becomes ready with labels:/, table(%{
    | #{pod_label} |
  })
  step %Q/evaluation of `pod` is stored in the :log_receiver clipboard/
end

Given /^(fluentd|rsyslog) receiver is deployed as (secure|insecure)(?: with (mTLS|mTLS_share|server_auth|server_auth_share) enabled)?(?: in the#{OPT_QUOTED} project)?$/ do | server, security, auth_type, project_name |
  project_name ||= "openshift-logging"
  project(project_name)
  if env.version_lt('4.6', user: user)
    file_dir = "#{BushSlicer::HOME}/testdata/logging/logforwarding"
  else
    file_dir = "#{BushSlicer::HOME}/testdata/logging/clusterlogforwarder"
  end
  case server
  when "fluentd"
    receiver_name = "fluentdserver"
    pod_label = "logging-infra=fluentdserver"
    if security == "secure"
      step %Q/I generate certs for the "fluentdserver" receiver in the "<%= project.name %>" project/
      unless tagged_upgrade?
        step %Q/I ensure "fluentdserver" secret is deleted from the "<%= project.name %>" project after scenario/
      end
      # create secret/fluentdserver for fluentd server pod
      step %Q/I run the :create_secret client command with:/, table(%{
        | name         | fluentdserver            |
        | secret_type  | generic                  |
        | from_file    | tls.key=logging-es.key   |
        | from_file    | tls.crt=logging-es.crt   |
        | from_file    | ca-bundle.crt=ca.crt     |
        | from_file    | ca.key=ca.key            |
        | from_literal | shared_key=fluentdserver |
        | n            | #{project_name}          |
      })
      step %Q/I create a pipeline secret with:/, table(%{
        | secret_name | pipelinesecret |
        | auth_type   | #{auth_type}   |
        | shared_key  | fluentdserver  |
      })
      step %Q/the step should succeed/
      # set configmap and create pipeline secret in openshift-logging project
      case auth_type
      when "mTLS_share"
        configmap_file = "#{file_dir}/fluentd/secure/cm-mtls-share.yaml"
      when "mTLS"
        configmap_file = "#{file_dir}/fluentd/secure/cm-mtls.yaml"
      when "server_auth"
        configmap_file = "#{file_dir}/fluentd/secure/cm-serverauth.yaml"
      when "server_auth_share"
        configmap_file = "#{file_dir}/fluentd/secure/cm-serverauth-share.yaml"
      else
        raise "Unrecognized auth type: #{auth_type}"
      end
      deployment_file = "#{file_dir}/fluentd/secure/deployment.yaml"
    else
      configmap_file = "#{file_dir}/fluentd/insecure/configmap.yaml"
      deployment_file = "#{file_dir}/fluentd/insecure/deployment.yaml"
    end

  when "rsyslog"
    receiver_name = "rsyslogserver"
    pod_label = "component=rsyslogserver"
    configmap_file = "#{file_dir}/rsyslog/insecure/rsyslogserver_configmap.yaml"
    deployment_file = "#{file_dir}/rsyslog/insecure/rsyslogserver_deployment.yaml"
  else
    raise "Unrecognized server: #{server}"
  end

  step %Q/I create the resources for the receiver with:/, table(%{
    | namespace       | #{project_name}    |
    | receiver_name   | #{receiver_name}   |
    | configmap_file  | #{configmap_file}  |
    | deployment_file | #{deployment_file} |
    | pod_label       | #{pod_label}       |
  })
end

# upgrade operator and check the EFK pods status
Given /^I upgrade the operator with:$/ do | table |
  opts = opts_array_to_hash(table.raw)
  subscription = opts[:subscription]
  channel = opts[:channel]
  catsrc = opts[:catsrc]
  namespace = opts[:namespace]
  project(namespace)

  # upgrade operator
  patch_json = {"spec": {"channel": "#{channel}", "source": "#{catsrc}"}}
  patch_opts = {resource: "subscription", resource_name: subscription, p: patch_json.to_json, n: namespace, type: "merge"}
  @result = admin.cli_exec(:patch, **patch_opts)
  raise "Patch failed with #{@result[:response]}" unless @result[:success]
  # wait till new csv to be installed
  success = wait_for(180, interval: 10) {
    subscription(subscription).installplan_csv.include? channel
  }
  raise "the new CSV can't be installed" unless success
  # wait till new csv is ready
  success = wait_for(600, interval: 10) {
    new_csv = subscription(subscription).current_csv(cached: false)
    cluster_service_version(new_csv).ready?[:success]
  }
  raise "can't upgrade operator #{subscription}" unless success

  #check if the EFK pods could be upgraded successfully
  project("openshift-logging")
  if cluster_logging('instance').log_store_spec != nil
    if elasticsearch('elasticsearch').exists?
      if subscription == "elasticsearch-operator"
        # check if the ES cluster could be upgraded
        success = wait_for(300, interval: 10) {
          elasticsearch('elasticsearch').nodes_status[0]["upgradeStatus"]["scheduledUpgrade"]
        }
        raise "Can't upgrade the ES cluster" unless success
      end
      # wait for the ES cluster to be ready
      success = wait_for(600, interval: 10) {
        elasticsearch('elasticsearch').cluster_health == "green" &&
        (elasticsearch('elasticsearch').nodes_status.last["upgradeStatus"].empty? ||
        elasticsearch('elasticsearch').nodes_status.last["upgradeStatus"]["scheduledUpgrade"].nil?)
      }
      raise "ES cluster isn't in a good status" unless success
      # check pvc count
      unless BushSlicer::PersistentVolumeClaim.list(user: user, project: project).count == cluster_logging('instance').logstore_node_count
        raise "The PVC count doesn't match the ES node count"
      end
    else
      raise "The elasticsearch/elasticsearch is not created"
    end
  end

  # check the kibana status
  if cluster_logging('instance').visualization_spec != nil
    if deployment('kibana').exists?
      success = wait_for(300, interval: 10) {
        (deployment('kibana').replica_counters(cached: false)[:desired] == deployment('kibana').replica_counters(cached: false)[:updated]) &&
        (deployment('kibana').replica_counters(cached: false)[:desired] == deployment('kibana').replica_counters(cached: false)[:available])
      }
      raise "Kibana isn't in a good status" unless success
    else
      raise "Deployment/kibana does not exist"
    end
  end

  # check fluentd status
  if cluster_logging('instance').collection_spec != nil
    if daemon_set('fluentd').exists?
      success = wait_for(300, interval: 10) {
        (daemon_set('fluentd').replica_counters(cached: false)[:desired] == daemon_set('fluentd').replica_counters(cached: false)[:updated_scheduled]) &&
        (daemon_set('fluentd').replica_counters(cached: false)[:desired] == daemon_set('fluentd').replica_counters(cached: false)[:available])
      }
      raise "Fluentd isn't in a good status" unless success
    else
      raise "Daemonset/fluentd doesn't exist"
    end
  end
end

# only check the major version, such as 4.4, 4.5, 4.6, don't care about versions like 4.6.0-2020xxxxxxxx
Given /^I make sure the logging operators match the cluster version$/ do
  step %Q/I switch to cluster admin pseudo user/
  # check if channel name in subscription is same to the target channel
  step %Q/cluster-logging channel name is stored in the :clo_channel clipboard/
  step %Q/elasticsearch-operator channel name is stored in the :eo_channel clipboard/
  step %Q/elasticsearch-operator catalog source name is stored in the :eo_catsrc clipboard/
  step %Q/cluster-logging catalog source name is stored in the :clo_catsrc clipboard/
  # check EO
  project("openshift-operators-redhat")
  eo_current_channel = subscription("elasticsearch-operator").channel(cached: false)
  eo_current_catsrc = subscription("elasticsearch-operator").source
  if cb.eo_channel != eo_current_channel || cb.eo_catsrc != eo_current_catsrc
    upgrade_eo = true
    step %Q/I upgrade the operator with:/, table(%{
      | namespace    | openshift-operators-redhat |
      | subscription | elasticsearch-operator     |
      | channel      | #{cb.eo_channel}           |
      | catsrc       | #{cb.eo_catsrc}            |
    })
    step %Q/the step should succeed/
  else
    upgrade_eo = false
  end
  # check CLO
  project("openshift-logging")
  clo_current_channel = subscription("cluster-logging").channel(cached: false)
  clo_current_catsrc = subscription("cluster-logging").source
  if clo_current_channel != cb.clo_channel || cb.clo_catsrc != clo_current_catsrc
    upgrade_clo = true
    step %Q/I upgrade the operator with:/, table(%{
      | namespace    | openshift-logging |
      | subscription | cluster-logging   |
      | channel      | #{cb.clo_channel} |
      | catsrc       | #{cb.clo_catsrc}  |
    })
    step %Q/the step should succeed/
  else
    upgrade_clo = false
  end
  # check cronjobs if the CLO or/and EO is upgraded
  project("openshift-logging")
  if (upgrade_eo || upgrade_clo) && (BushSlicer::CronJob.list(user: user, project: project).count != 0)
    step %Q/I check the cronjob status/
    step %Q/the step should succeed/
  end
end

# check cronjob status
# delete all the jobs, and wait up to 15min to check the jobs status
Given /^I check the cronjob status$/ do
  # check logging version
  step %Q/I switch to cluster admin pseudo user/
  project("openshift-operators-redhat")
  eo_version = subscription("elasticsearch-operator").current_csv(cached: false)[23..-1].split('-')[0]
  project("openshift-logging")
  clo_version = subscription("cluster-logging").current_csv(cached: false)[16..-1].split('-')[0]
  #csv version >= 4.5, check rollover/delete cronjobs, csv < 4.5, only check curator cronjob
  if ["4.0", "4.1", "4.2", "4.3", "4.4"].include? clo_version.split('.').take(2).join('.')
    if cron_job('curator').exists?
      # remove all the old jobs
      @result = admin.cli_exec(:delete, object_type: 'job', l: 'component=curator', n: 'openshift-logging')
      # wait up to 6 minutes for the cronjob to be recreated
      success = wait_for(360, interval: 10) {
        BushSlicer::Job.list(user: user, project: project).count >= 1
      }
      raise "can't recreate cronjobs" unless success
    else
      raise "cronjob curator doesn't exist"
    end
  else
    cj_names = ["elasticsearch-im-app", "elasticsearch-im-audit", "elasticsearch-im-infra"]
    for cj_name in cj_names do
      raise "cronjob #{cj_name} doesn't exist" unless cron_job(cj_name).exists?
    end
    # remove all the old jobs
    @result = admin.cli_exec(:delete, object_type: 'job', l: 'component=indexManagement', n: 'openshift-logging')
    # wait up to 16 minutes for the cronjob to be recreated
    success = wait_for(960, interval: 10) {
      BushSlicer::Job.list(user: user, project: project).count >= 3
    }
    raise "can't recreate cronjobs" unless success
  end

  # check the new jobs could be successfully
  # wait up to 1 minute for the jobs to complete
  jobs = BushSlicer::Job.list(user: user, project: project)
  job_names = jobs.map(&:name)
  for job_name in job_names
    success = wait_for(60, interval: 5) {
      job(job_name).succeeded == 1
    }
    raise "#{job_name} failed to complete" unless success
  end
end

# This step will deploy one kafka cluster and create 4 topics(topic-logging-all,topic-logging-infra,topic-logging-app,topic-logging-audit) in this kafka
Given /^I deploy kafka in the #{QUOTED} project via amqstream operator$/ do | project_name|
  ensure_admin_tagged
  step %Q/I switch to cluster admin pseudo user/
  kafka_catsrc = package_manifest("amq-streams").catalog_source

  step %Q/I use the "#{project_name}" project/
  step %Q/I process and create:/, table(%{
    | f | #{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/kafka/amq/02_og_amqstreams_template.yaml |
    | p | AMQ_NAMESPACE=#{project_name} |
  })
  raise "Error create operatorgroup" unless @result[:success]

  step %Q/I process and create:/, table(%{
    | f | #{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/kafka/amq/03_sub_amqstreams_template.yaml |
    | p | AMQ_NAMESPACE=#{project_name}     |
    | p | AMQ_CATALOGSOURCE=#{kafka_catsrc} |
  })
  raise "Error subscript amqstreams" unless @result[:success]

  step %Q/a pod becomes ready with labels:/, table(%{
    | name=amq-streams-cluster-operator |
  })

  step %Q/I process and create:/, table(%{
    | f | #{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/kafka/amq/04_kafka_my-cluster_amqstreams_template.yaml |
    | p | AMQ_NAMESPACE=#{project_name} |
  })
  raise "Error create kafka" unless @result[:success]

  @result = admin.cli_exec(:create, f: "#{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/kafka/amq/05_kafkatopics_amqstreams.yaml")
  raise "Error create kafka topics" unless @result[:success]

  step %Q/3 pods becomes ready with labels:/, table(%{
    | strimzi.io/name=my-cluster-kafka |
  })
  raise "Error kafka cluster not ready" unless @result[:success]
end

# Get some records from a kafka topic
# https://datacadamia.com/dit/kafka/kafka-console-consumer
Given /^I get(?: (\d+))? records from the #{QUOTED} kafka topic in the #{QUOTED} project$/ do | record_num, topic_name, project_name|
  record_num = record_num ? record_num.to_str : "10"
  job_name=rand_str(8, :dns)
  step %Q/I use the "#{project_name}" project/
  kafka_image=stateful_set('my-cluster-kafka').containers_spec(user: user)[0].image
  teardown_add {
    admin.cli_exec(:delete, object_type: 'job', object_name_or_id: job_name, n: project_name)
  }
  step %Q/I process and create:/,table(%{
    | f | #{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/kafka/amq/21_job_topic_consumer_from_beginning_template.yaml |
    | p | KAFKA_IMAGE=#{kafka_image} |
    | p | KAFKA_TOPIC=#{topic_name}  |
    | p | MAX_MESSAGES=#{record_num} |
    | p | JOB_NAME=#{job_name} |
  })
  step %Q/a pod becomes ready with labels:/, table(%{
    | job-name=#{job_name}|
  })

  # wait up to 1 minutes for the kafka message
  success = wait_for(60, interval: 15) {
    @result = user.cli_exec(:logs, {resource_name: "#{pod.name}"})
    @result[:response].match("pipeline_metadata")
  }
  raise "Couldn't received logs from the kafka topic #{topic_name}" unless success
end

# Register an topic consumer which listen the topic continuously. we can verify the logging records by the next step 'I get N logs from the X kafka consumer job'
Given /^I create the #{QUOTED} consumer job to the #{QUOTED} kafka topic in the #{QUOTED} project$/ do | job_name, topic_name, project_name |
  step %Q/I use the "#{project_name}" project/
  kafka_image=stateful_set('my-cluster-kafka').containers_spec(user: user)[0].image
  teardown_add {
    admin.cli_exec(:delete, object_type: 'job', object_name_or_id: job_name, n: project_name)
  }
  step %Q/I process and create:/,table(%{
    | f | #{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/kafka/amq/21_job_topic_consumer_from_latest_template.yaml |
    | p | KAFKA_IMAGE=#{kafka_image} |
    | p | KAFKA_TOPIC=#{topic_name} |
    | p | JOB_NAME=#{job_name} |
  })
  raise "Unable to create consumer job" unless @result[:success]
end

# Get logs from the kafka comsumer job which created by upper job
Given /^I get(?: (\d+))? logs from the #{QUOTED} kafka consumer job in the #{QUOTED} project$/ do | record_num, job_name, project_name |
  record_num = record_num ? record_num.to_i : 0
  step %Q/I use the "#{project_name}" project/
  step %Q/a pod becomes ready with labels:/, table(%{
    | job-name=#{job_name}|
  })

  # wait up to 1 minutes for the kafka message
  success = wait_for(60, interval: 10) {
    if record_num >0
      @result = user.cli_exec(:logs, {resource_name: "#{pod.name}", tail: "#{ record_num }"})
    else
      @result = user.cli_exec(:logs, {resource_name: "#{pod.name}"})
    end
    @result[:response].match("pipeline_metadata")
  }
  raise "Couldn't retrieve kafka records #{pod.name}" unless success
end

# deploy external elasticsearch server
# version: 6.8 or 7.12
# project_name: where the external ES deployed
# scheme: http or https
# transport_ssl_enabled: true or false
# user_auth_enabled: true or false, if `true`, must provide username and password
# secret_name: the name of the pipeline secret for the fluentd to use
Given /^external elasticsearch server is deployed with:$/ do | table |
  opts = opts_array_to_hash(table.raw)
  version = opts[:version] # 6.8 or 7.12
  project_name = opts[:project_name]
  scheme = opts[:scheme]
  transport_ssl_enabled = opts[:transport_ssl_enabled]
  user_auth_enabled = opts[:user_auth_enabled]
  username = opts[:username]
  password = opts[:password]
  secret_name = opts[:secret_name]
  project(project_name)

  unless ["6.8", "7.12"].include? version
    raise "Unsupported ES version: #{version}, we only support ES 6.8 and 7.12!"
  end

  if scheme == "https"
    http_ssl_enabled = "true"
  else
    http_ssl_enabled = "false"
  end

  if user_auth_enabled == "true"
    raise "username or password is not specified" unless !(username.nil? || username.empty?) && !(password.nil? || password.empty?)
  end

  file_dir = "#{BushSlicer::HOME}/testdata/logging/clusterlogforwarder/elasticsearch/#{version}/#{scheme}"
  receiver_name = "elasticsearch-server"
  pod_label = "app=elasticsearch-server"

  # create secret/elasticsearch-server for ES if needed
  if transport_ssl_enabled == "true" || scheme == "https"
    step %Q/I generate certs for the "elasticsearch-server" receiver in the "<%= project.name %>" project/
    unless tagged_upgrade?
      step %Q/I ensure "elasticsearch-server" secret is deleted from the "<%= project.name %>" project after scenario/
    end
    step %Q/I run the :create_secret client command with:/, table(%{
      | name        | elasticsearch-server                |
      | secret_type | generic                             |
      | from_file   | logging-es.key=logging-es.key       |
      | from_file   | logging-es.crt=logging-es.crt       |
      | from_file   | elasticsearch.key=elasticsearch.key |
      | from_file   | elasticsearch.crt=elasticsearch.crt |
      | from_file   | admin-ca=ca.crt                     |
      | n           | #{project_name}                     |
    })
    step %Q/the step should succeed/
  end

  if user_auth_enabled == "true" || transport_ssl_enabled == "true" || http_ssl_enabled == "true"
    raise "secret_name is not specified or is empty" unless !(secret_name.nil? || secret_name.empty?)
    step %Q/I create a pipeline secret with:/, table(%{
      | secret_name           | #{secret_name}           |
      | username              | #{username}              |
      | password              | #{password}              |
      | transport_ssl_enabled | #{transport_ssl_enabled} |
      | user_auth_enabled     | #{user_auth_enabled}     |
      | http_ssl_enabled      | #{http_ssl_enabled}      |
    })
  end

  # chose files per transport_ssl_enabled and user_auth_enabled
  if transport_ssl_enabled == "true" && user_auth_enabled == "true"
    step %Q/I run the :process client command with:/, table(%{
      | f | #{file_dir}/user_auth_with_transport_tls/configmap.yaml |
      | p | USERNAME=#{username} |
      | p | PASSWORD=#{password} |
    })
    File.write(File.expand_path("cm.yaml".strip), @result[:stdout])
    cm = "cm.yaml"
    deploy = "#{file_dir}/user_auth_with_transport_tls/deployment.yaml"
  elsif transport_ssl_enabled == "true" && user_auth_enabled != "true"
    cm = "#{file_dir}/transport_tls/configmap.yaml"
    deploy = "#{file_dir}/transport_tls/deployment.yaml"
  elsif transport_ssl_enabled != "true" && user_auth_enabled == "true"
    step %Q/I run the :process client command with:/, table(%{
      | f | #{file_dir}/user_auth/configmap.yaml |
      | p | USERNAME=#{username} |
      | p | PASSWORD=#{password} |
    })
    File.write(File.expand_path("cm.yaml".strip), @result[:stdout])
    cm = "cm.yaml"
    deploy = "#{file_dir}/user_auth/deployment.yaml"
  else
    cm = "#{file_dir}/insecure/configmap.yaml"
    deploy = "#{file_dir}/insecure/deployment.yaml"
  end

  step %Q/I create the resources for the receiver with:/, table(%{
    | namespace       | #{project_name}  |
    | receiver_name   | #{receiver_name} |
    | configmap_file  | #{cm}            |
    | deployment_file | #{deploy}        |
    | pod_label       | #{pod_label}     |
  })
end

Given /^The #{WORD} user create #{QUOTED} logs in project #{QUOTED}$/ do | who, log_type, project_name |
    file_dir = "#{BushSlicer::HOME}/testdata/logging/loggen"
    user(word_to_num(who))

    unless project(project_name).exists?
        step %Q/I run the :new_project client command with:/,table(%{
          | project_name | #{project_name} |
        })
        raise "Error creating namespace" unless @result[:success]
    end

    case log_type
      when "json"
        template_file = "#{file_dir}/container_json_log_template.json"
      when "flat"
        template_file = "#{file_dir}/container_json_unicode_log_template.json"
      when "unicode"
        template_file = "#{file_dir}/container_json_unicode_log_template.json"
      else
        template_file = "#{file_dir}/container_json_log_template.json"
      end

    unless  project.pods(by:user).size > 0 
        step %Q/I run the :new_app client command with:/,table(%{
           | file | #{template_file} |
         })
    end
end

Given /^The #{WORD} user create index pattern #{QUOTED} in kibana$/ do | who, pattern_name |
    user(word_to_num(who))
    step %Q/I login to kibana logging web console/
    raise "#{user.name} can not login kibana" unless @result[:success]
    success = wait_for(300, interval: 10) {
        step %Q/I run the :go_to_kibana_discover_page web action/
    }
    unless success
        step %Q/I perform the :kibana_find_index_pattern web action with:/,table(%{
            | index_pattern_name | #{pattern_name} |
         })
    end
    unless @result[:success]
        step %Q/I perform the :create_index_pattern web action with:/, table(%{
            | index_pattern_name | #{pattern_name} |
         })
    end
    raise "#{user.name} can not find&create pattern #{pattern_name} in kibana" unless @result[:success]

    #<input type="text" id="90bgva7z" name="indexPattern" placeholder="index-name-*" class="euiFieldText" data-test-subj="createIndexPatternNameInput" aria-describedby="90bgva7z-help" value="app*">
    #<select id="hhmx8out" name="timeField" class="euiSelect" data-test-subj="createIndexPatternTimeFieldSelect" aria-describedby="hhmx8out-help">
    #<option value="" selected=""></option>
    #<option value="@timestamp">@timestamp</option>
    #<option value="kubernetes.event.firstTimestamp">kubernetes.event.firstTimestamp</option>
    #<option value="pipeline_metadata.collector.received_at">pipeline_metadata.collector.received_at</option>
    #<option value="pipeline_metadata.normalizer.received_at">pipeline_metadata.normalizer.received_at</option>
    #<option value="">───</option>
    #<option>I don't want to use the Time Filter</option>
    #</select>
end

Given /^The #{WORD} user can display #{QUOTED} project logs under pattern#{OPT_QUOTED} in kibana$/ do | who, project_name, pattern_name |
    step %Q/I switch to cluster admin pseudo user/
    clo_current_channel = subscription("cluster-logging").channel(cached: false)

    user(word_to_num(who))
    step %Q/I login to kibana logging web console/
    # check the log count, wait for the Kibana console to be loaded
    raise "#{user.name} can not login kibana" unless @result[:success]

    if(['4.1', '4.2', '4.3', '4.4'].include?(clo_current_channel))
         if(project_name.match("openshift-") && project_name.match("kube-") && project_name == "default")
             pattern_name ||= ".operation"
         else
             pattern_name ||= "project.#{project_name}"
         end
         step %Q/I run the :go_to_kibana_discover_page web action/
         step %Q/I perform the :kibana_find_index_pattern web action with:/,table(%{
            | index_pattern_name | #{pattern_name} |
         })
         raise "#{user.name} can not find the pattern project.#{project_name}... " unless @result[:success]
         success = wait_for(300, interval: 10) {
            step %Q/I run the :check_log_count web action/
            #@result = browser.run_action("check_log_count web action")
         }
         raise "#{user.name} can not find logs under pattern project.#{project_name}... in kibana" unless success
    else
         if(project_name.match("openshift-") && project_name.match("kube-") && project_name == "default")
             pattern_name ||= "infra"
             check_pattern_name="i*nfra"
         else
             pattern_name ||= "a*pp"
             real_pattern_name=pattern_name.insert(1, '*') 
         end
         step %Q/I run the :go_to_kibana_discover_page web action/
         step %Q/I perform the :kibana_find_index_pattern web action with:/,table(%{
            | index_pattern_name | #{real_pattern_name}|
         })

         unless @result[:success]
             step %Q/I run the :go_to_kibana_management_page web action/
             raise "#{user.name} can not go into Index Patterns page" unless @result[:success]

             step %Q/I perform the :create_index_pattern web action with:/, table(%{
                 | index_pattern_name | #{pattern_name} |
             })
             raise "#{user.name} can not find&create pattern #{pattern_name} in kibana" unless @result[:success]
             step %Q/I run the :go_to_kibana_discover_page web action/
         end 

         success = wait_for(300, interval: 10) {
            step %Q/I run the :check_log_count web action/
         }
         raise "#{user.name} can not find logs under pattern #{pattern_name} in kibana" unless success
    end
end
