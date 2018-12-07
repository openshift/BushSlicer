require 'openshift/project_resource'

module VerificationTests
  # represnets an Openshift StatefulSets
  class StatefulSet < PodReplicator
    RESOURCE = "statefulsets"
    REPLICA_COUNTERS = {
      desired:   %w[spec replicas].freeze,
      current:   %w[status replicas].freeze
    }.freeze
  end
end
