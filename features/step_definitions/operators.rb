# operators related helper steps
Given /^all clusteroperators reached version #{QUOTED} successfully$/ do |version|
  ensure_admin_tagged
  clusteroperators = BushSlicer::ClusterOperator.list(user: admin)
  clusteroperators.each do | co |
    raise "version does not match #{version}" unless co.version_exists?(version: version)
    # AVAILABLE   PROGRESSING   DEGRADED
    # True        False         False
    conditions = co.conditions
    expected = {"Degraded"=>"False", "Progressing"=>"False", "Available"=>"True"}
    conditions.each do |c|
      # only care about the `expected`, don't compare otherwise
      if expected.keys.include? c['type']
        expected_status = expected[c['type']]
        raise "Failed for condition #{c['type']}, expected: #{expected_status}, got: #{c['status']}" unless expected_status == c['status']
      end
    end
  end
end

Given /^the status of condition "([^"]*)" for "([^"]*)" operator is: (.+)$/ do | type, operator, status |
  ensure_admin_tagged
  actual_status = cluster_operator(operator).condition(type: type, cached: false)['status']
  unless status == actual_status
    raise "status of #{operator} condition #{type} is #{actual_status}"
  end
end

Given /^the "([^"]*)" operator version matchs the current cluster version$/ do | operator |
  ensure_admin_tagged
  @result = admin.cli_exec(:get, resource: "clusteroperators", resource_name: operator, o: "jsonpath={.status.versions[?(.name == \"operator\")].version}")
  operator_version = @result[:response]

  @result = admin.cli_exec(:get, resource: "clusterversion", resource_name: "version", o: "jsonpath={.status.desired.version}")
  cluster_version = @result[:response]

  raise "The #{operator} version doesn't match the current cluster version" unless operator_version == cluster_version
  logger.info("### the cluster version is #{cluster_version}")
end

Given /^admin updated the operator crd "([^"]*)" managementstate operand to (Managed|Removed|Unmanaged)$/ do |cluster_operator, manage_type|
  ensure_admin_tagged
  ensure_destructive_tagged
  step %Q/I run the :patch admin command with:/, table(%{
    | resource      | #{cluster_operator}.operator.openshift.io      |
    | resource_name | cluster                                        |
    | p             | {"spec":{"managementState": "#{manage_type}"}} |
    | type          | merge                                          |
  })
  step %Q/the step should succeed/
end
