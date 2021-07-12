require 'net/https'
require 'thread'

module BushSlicer
  class Jenkins
    include Common::Helper

    attr_accessor :client, :build_map, :bm_sorted_keys, :build_user_map
    def initialize
      url = "https://#{conf[:services][:jenkins][:host]}"
      @client = JenkinsApi::Client.new(:server_url => url,
         :username => ENV['JENKINS_USER'], :password => ENV['JENKINS_PASSWORD'])
      # # xxx for debugging you can set @build_map manually and disable to
      # init call in cloud_cop.rb to save time querying jenkins server
      # repeatedly
      #
      #  @build_map =  {"qeci-293"=>69641,
      #  ...
      #  "juzhao-1023"=>69559}
    end

    # @return <Array of builds>
    def get_builds(job_name)
      return client.job.get_builds(job_name)
    end

    def get_build_details(build_id: nil, job_name: "Launch Environment Flexy")
      return client.job.get_build_details(job_name, build_id)
    end

    # @return INSTANCE_NAME_PREFIX information from a build detail
    # actions[action_index]['parameters'][param_index]['name'] == "INSTANCE_NAME_PREFIX"
    def get_instance_prefix_from_build(build_id: nil)
      bd = self.get_build_details(build_id: build_id)
      instance_name_prefix = ""
      bd['actions'].each do |action|
        action.each do |a|
          if a.include? "hudson.model.ParametersAction"
            instance_name_prefix = action['parameters'].map { |p| p['value'] if p['name']== "INSTANCE_NAME_PREFIX" }.compact.first
            break
          end
        end
      end
      return instance_name_prefix
    end

    def construct_jenkins_build_map
      threads = []
      thread_count= 15
      # API only limits at 100 at the moment...should be sufficient
      builds = get_builds('Launch Environment Flexy')
      build_map = {}
      builds.each_slice(thread_count) do | build |
        threads << Thread.new(build) do |b_list|
          b_list.each do | b|
            instance_build_prefix = get_instance_prefix_from_build(build_id: b['number'])
            build_map[instance_build_prefix] = b['number']
          end
        end
      end
      threads.each { |thr| thr.join }
      self.build_map = build_map
      self.bm_sorted_keys = build_map.keys.sort
      return build_map, build_map.keys.sort
    end

    # @return job id or 'Not found is none is matched and the name of the cluster
    # 1. filter out build_map entries by filtering out by first few characters
    #    in the inst_group_name
    #
    def get_jenkins_flexy_job_id(inst_group_name)
      f_keys = bm_sorted_keys.select { |k| k.start_with? inst_group_name.split('-').first }
      #f_keys = bm_sorted_keys.select { |k| k.start_with? inst_group_name[0..6] }
      index = f_keys.select { |k| inst_group_name.start_with? k}.first

      if index
        return self.build_map[index], index
      else
        return "not found", nil
      end
    end

  end

end
