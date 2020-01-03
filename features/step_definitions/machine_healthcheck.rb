When(/^I create the 'Ready' unhealthyCondition$/) do
  ensure_destructive_tagged

  # pick a random node from the machines
  machines = BushSlicer::Machine.list(user: admin, project: project("openshift-machine-api")).
    select { |m| m.machine_set_name == machine_set.name }
  cache_resources *machines.shuffle

  # somtimes PDB may prevent a successful node-drain thus blocks the test
  # annnotate the machine to exclude node-drain so that test does not flake
  step %Q{I run the :annotate client command with:}, table(%{
    | n            | openshift-machine-api                       |
    | resource     | machine                                     |
    | resourcename | #{machine.name}                             |
    | overwrite    | true                                        |
    | keyval       | machine.openshift.io/exclude-node-draining= |
  })

  # create a priviledged pod that kills kubelet on its node
  step %Q{I run oc create over "https://raw.githubusercontent.com/openshift-qe/v3-testfiles/master/cloud/mhc/kubelet-killer-pod.yml" replacing paths:}, table(%{
    | n                    | openshift-machine-api |
    | ["spec"]["nodeName"] | #{machine.node_name}  |
  })
  step %Q{the step should succeed}
end

Then(/^the machine should be remediated$/) do
  # unhealthy machine and should be deleted
  step %Q{I wait for the resource "node" named "<%= machine.node_name %>" to disappear within 600 seconds}
  step %Q{I wait for the resource "machine" named "<%= machine.name %>" to disappear within 600 seconds}

  # new machine and node should provisioned
  step %Q{the machineset should have expected number of running machines}
end
