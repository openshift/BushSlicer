require 'openshift/cluster_resource'

module BushSlicer
  # represents Machine
  class Machine < ProjectResource
    RESOURCE = 'machines'

    def machine_set_name(user: nil, cached: true, quiet: false)
      raw_resource(user: user, cached: cached, quiet: quiet).
        dig('metadata', 'labels', 'machine.openshift.io/cluster-api-machineset')
    end

    # returns the node name the machine linked to
    def node_name(user: nil, cached: true, quiet: false)
      raw_resource(user: user, cached: cached, quiet: quiet).
        dig('status', 'nodeRef', 'name')
    end

    def provider_id(user: nil, cached: true, quiet: false)
      raw_resource(user: user, cached: cached, quiet: quiet).
        dig('spec', 'providerID')
    end

    def phase(user: nil, cached: true, quiet: false)
      raw_resource(user: user, cached: cached, quiet: quiet).
        dig('status','phase')
    end

    def instance_state(user: nil, cached: true, quiet: false)
      rr = raw_resource(user: user, cached: cached, quiet: quiet)
      rr.dig('status', 'providerStatus', 'instanceState') ||
      rr.dig('status', 'providerStatus', 'vmState')
    end

    def annotation_instance_state(user: nil, cached: true, quiet: false)
      raw_resource(user: user, cached: cached, quiet: quiet).
          dig('metadata', 'annotations', 'machine.openshift.io/instance-state')
    end

    def ready?(user: nil, cached: true, quiet: false)
      instance_state = raw_resource(user: user, cached: cached, quiet: quiet).
        dig('status','providerStatus','instanceState')
      instance_state == 'running'
    end

    def azure_location(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'location')
    end

    def gcp_region(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'region')
    end

    def gcp_zone(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'zone')
    end
     
    def gcp_service_account(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'serviceAccounts')
    end

    def aws_ami_id(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'ami','id')
    end

    def aws_availability_zone(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'placement','availabilityZone')
    end

    def aws_subnet(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'subnet','id')
    end

    def aws_iamInstanceProfile(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'iamInstanceProfile', 'id')
    end

    def vsphere_datacenter(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'workspace', 'datacenter')
    end

    def vsphere_datastore(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'workspace', 'datastore')
    end

    def vsphere_folder(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'workspace', 'folder')
    end

    def vsphere_resourcePool(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'workspace', 'resourcePool')
    end

    def vsphere_server(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'workspace', 'server')
    end

    def vsphere_diskGiB(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'diskGiB')
    end

    def vsphere_memoryMiB(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'memoryMiB')
    end
    
    def vsphere_template(user: nil, cached: true, quiet: false)
       raw_resource(user: user, cached: cached ,quiet: quiet).
         dig('spec', 'providerSpec', 'value', 'template')
    end

    def deleting?(user: nil, cached: true, quiet: false)
      ! raw_resource(user: user, cached: cached, quiet: quiet).
          dig('metadata', 'deletionTimestamp').nil?
    end
  end
end
