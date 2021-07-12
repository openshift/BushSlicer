require 'text-table'
require 'thread'
# require 'pry-byebug'

module BushSlicer

  # base class to display a summary of the current running instances.
  # Currently display ['name', 'uptime', 'flexy_job_id', 'region'] in a
  # tabulized format

  class InstanceSummary
    attr_accessor :jenkins

    def initialize(jenkins)
      @jenkins = jenkins
    end

    ## print out summary in a text table format
    def print_summary(summary)
      table = Text::Table.new
      has_instance_type = summary.first.keys.include? :type

      if has_instance_type
        table.head = ['name', 'uptime', 'flexy_job_id', 'type', 'cost ($)', 'region', 'inst_prefix']
      else
        table.head = ['name', 'uptime', 'flexy_job_id', 'region', 'inst_prefix']
      end
      summary.each do | s |
        if has_instance_type
          row = [s[:name], s[:uptime], s[:flexy_job_id], s[:type], s[:cost], s[:region], s[:inst_prefix]]
        else
          row = [s[:name], s[:uptime], s[:flexy_job_id], s[:region], s[:inst_prefix]]
        end
        table.rows << row
      end
      puts table
      print "There are #{summary.count} running instances in #{summary.first[:region]}\n"
    end

    # print a table of summary of all of the instances grouped by region
    def print_grand_summary(summary)
      table = Text::Table.new
      total_cost = 0.0
      has_cost = summary.first.keys.include? :total_cost
      if has_cost
        table.head = ['platform', 'region', 'total instances', 'costs ($)']
        summary.each {|s| total_cost += s[:total_cost]}
      else
        table.head = ['platform', 'region', 'total instances']
      end
      total = 0
      grand_total_cost = 0.0
      summary.each do |s|
        total += s[:inst_count]
        if has_cost
          table.rows << [s[:platform], s[:region], s[:inst_count], s[:total_cost].round(2)]
          grand_total_cost += s[:total_cost]
        else
          table.rows << [s[:platform], s[:region], s[:inst_count]]
        end
      end
      if has_cost
        table.foot = ["Total instances", "", total, grand_total_cost.round(2)]
      else
        table.foot = ["Total instances", "", total]
      end
      puts table
    end
    # given a list of users, separate them into a valid_users and unknown_users
    # list
    # @return Hash of Array, 'valid' and 'unknown'
    def validate_users(users_map: nil, users_list: nil)
      valid_users = []
      unknown_users = []
      auto_names_reg_exp = /^((qeci|udg)-\d{5})/
      users_hash = {}
      users_list.each do |u|
        res = users_map.select {|a| u.include? a }
        if res.count > 0
          valid_users << res.first
        else
          begin
            match = auto_names_reg_exp.match(u)
          rescue
            match = nil
          end
          # try to catch qeci and ugd ci user name
          if match
            # strip out the last 6 charcters
            u = match[1]
          end
          unknown_users << u
        end
      end
      users_hash[:valid] = valid_users
      users_hash[:unknown] = unknown_users
      users_hash
    end

    def print_condensed_usage(usage: nil, options: nil)
      user_map = @jenkins.build_user_map
      res_list = []
      users = []
      has_cost = false
      usage.each do | k, v |
        if v.has_key? :total_cost
          user_info = user_map[v[:job_id]]
          user_info = v[:user] if user_info.nil?
          # force it to k if user_info is nil
          user_info ||= k
          users << user_info
          res_list << [k, v[:job_id], v[:uptime].round(2), v[:total_cost], user_info]
          has_cost = true
        else
          res_list << [k, v[:job_id], v[:uptime].round(2), user_map[v[:job_id]]]
        end
      end
      users.uniq!
      table = Text::Table.new
      if has_cost
        table.head = ['name', 'job_id', 'uptime', 'total_cost ($)', 'user']
      else
        table.head = ['name', 'job_id', 'uptime', 'user']
      end
      res_list.each do |r|
        if has_cost
          table.rows << [r[0], r[1], r[2], r[3], r[4]]
        else
          table.rows << [r[0], r[1], r[2], r[3]]
        end
      end
      if table.rows.count > 0
        msg = "\nThese '#{options.platform}' clusters have been alive longer than #{options.uptime} hrs.\n"
        print msg
        puts table
        send_to_slack(summary_text: msg + table.to_s, options: options) unless options.no_slack
        # tag the users of the long-lived clusters
        # for Packet platform, we ignore host that ends with  'aux'
        if self.class == BushSlicer::PacketSummary
          filtered_list = res_list.select {|r| r[4] unless r[0].end_with? '-aux'}
          users = filtered_list
        # Special case for vSphere where `Workload` user is not real, so just
        # ignore it
        elsif self.class == BushSlicer::VSphereSummary
          filtered_list = res_list.map {|r| r[4] if r[0] !='Workloads' }.compact
          users = filtered_list
        end

        valid_users, unknown_users = translate_to_slack_users(users: users)
        tag_users_msg =  valid_users + " please terminate your long-lived clusters if they are no longer in use\n"
        tag_users_msg += "\nThese clusters have no owners association #{unknown_users}\n" if unknown_users.size > 0
        #tag_users_msg = "<@UBET0LUR3> please terminate your long-lived clusters if they are no longer in use"
        options.slack_no_block_format = true
        send_to_slack(summary_text: tag_users_msg, options: options) unless options.no_slack
      end
    end

    # @returns a list of users' slack user_ids and list of unknown users
    def translate_to_slack_users(users: nil)
      # 1. get the slacker_users lookup map
      users_map_hash = YAML.load(open(File.expand_path("creds/slack_users_map.yaml")))
      # 2. separate valid users from unknown into their buckets
      users_hash = validate_users(users_map: users_map_hash.keys, users_list: users)

      slack_user_ids = users_hash[:valid].map { |u| "<@#{users_map_hash.dig(u)}>" }
      [slack_user_ids.join(" "), users_hash[:unknown].join(" ")]
    end

    def extract_cluster_name(name_str)
      auto_names_reg_exp = /^((qeci|udg)-\d{5})/
      names_reg_exp = /^[\d\w]+-[\d\w]{2,5}/

      auto_name_match = auto_names_reg_exp.match(name_str)
      reg_name_match = names_reg_exp.match(name_str)
      if auto_name_match
        auto_name_match[0]
      elsif reg_name_match
        reg_name_match[0]
      else
        name_str[0..12]
      end
    end

    # given a summary list of clusters, compact the return by grouping the
    # resources under the same cluster as one.
    def compact_results(res)
      c_hash = {}
      not_found_keys = []
      # save the unique cluster by grouping them by the :owner field
      owners = res.map { |r|
        if r[:region] == 'vSphere'
          r[:owned]
        else
          extract_cluster_name(r[:name])
        end
      }.uniq

      #   auto_names_reg_exp = /^((qeci|udg)-\d{5})/
      #   names_reg_exp = /^[\d\w]+-[\d\w]{2,5}-/
      #   if r[:owned].nil? and r[:region] != 'vSphere'
      #     r[:name]
      #     # r[:name] + "_no_owner"
      #   # special case for Packet
      #   elsif r[:region] == "packet"
      #     r[:name]
      #     #else r[:region] == "aws" or r[:region] == "azure" or r[:region] == "gce"
      #   else
      #     auto_name_match = auto_names_reg_exp.match(r[:name])
      #     reg_name_match = names_reg_exp.match(r[:name])
      #     if auto_name_match
      #       auto_name_match[0]
      #     elsif reg_name_match
      #       reg_name_match[0]
      #     else
      #       r[:name][0..12]
      #     end
      #   end
      # }.uniq
      owners.sort.each do |owner|
        cluster_total_cost = 0.0
        # group them together
        if owner.end_with? '_no_owner'
          cluster_group = res.select {|r| r[:name] == owner.split('_no_owner').first}
        # special handling for Packet
        elsif owner.end_with? '-aux-server'
          cluster_group = res.select {|r| r[:name] == owner}
        else
          cluster_group = res.select {|r|
            if r[:owned].nil? or r[:region] == 'packet'
              owner_str = r[:name]
            elsif r[:region] == 'vSphere'
              owner_str = r[:owned]
            else
              owner_str = r[:owned]
            end
            owner_str.include? owner
          }
        end
        sample = cluster_group.first
        unless sample.nil?
          # calculate the total cost unless it's `openstack` which is `free`,
          # vsphere calculation is skipped due to complication
          unless cluster_group.first[:region] == "openstack" or cluster_group.first[:region] == 'vSphere'
            begin
              cluster_group.each {|r| cluster_total_cost += r[:cost]}
            rescue
              puts "##### exception occured while calculating the total cost!\n"
            end
          end
          # try to get the owner of the job which would be displayed in the
          # summary
          job_id = sample[:flexy_job_id]
          unless sample[:owned].nil?
            sample[:owned] =  sample[:owned].split('@redhat.com').first
          end
          c_hash[owner] = {'job_id': job_id, 'uptime': sample[:uptime], 'total_cost': cluster_total_cost.round(2), 'user': sample[:owned] }
        end
      end
      return c_hash
    end

    def print_longlived_clusters(summary, options)
      options.uptime ||= 18
      res = get_longlived_clusters(summary, options)
      ### special case for Packet, in which if the names ends with `-aux-server`, then do not tag the owners
      if res.count > 0
        res = compact_results(res)
        print_condensed_usage(usage: res, options: options)
      end
    end

    def get_longlived_clusters(summary, options)
      # special case for Openstack, we don't display preserved instances
      if summary.first[:region] != 'openstack'
        summary.select { |s| (s[:uptime] > options.uptime.to_i)}
      else
        summary.select { |s| (s[:uptime] > options.uptime.to_i) and (!(s[:name].include? 'preserve'))}
      end
    end



    # call Slack webhook to send text to a particular channel.
    # slack channel URL is defined in private/config/config.yaml
    ## TODO: research doing it via ruby-slack-client instead
    def send_to_slack(summary_text: text, options: nil)
      # for actual channel #forum-qe
      url = options.config.dig('services', 'slack', 'webhooks', 'channels')[0]['url']
      ## for debugging
      #url = options.config.dig('services', 'slack', 'webhooks', 'channels')[2]['url']
      opts = {:url => url, :method => "POST"}
      if options.slack_no_block_format
        opts[:payload] = %Q/{"blocks": [{"type": "section","text": {"type":"mrkdwn","text": "#{summary_text}"}}]}/
      else
        opts[:payload] = %Q/{"blocks": [{"type": "section","text": {"type":"mrkdwn","text": "```#{summary_text}```"}}]}/
      end
      res = Http.request(**opts)
    end
  end

  class AwsSummary < InstanceSummary
    attr_accessor :amz, :amz_prices
    def initialize(jenkins: nil)
      @amz = Amz_EC2.new
      @jenkins = jenkins
      @table = Text::Table.new
      # hard-coded pricing lookup table name: => price/hr
      @amz_prices = {
        "i3.large" => 0.15,
        "m5.xlarge" => 0.192,
        "m5.2xlarge" => 0.384,
        "m5.4xlarge" => 0.768,
        "m5.8xlarge" => 1.536,
        "m5.large" => 0.096,
        "m5a.xlarge"	 =>0.172,
        "m5a.2xlarge" => 0.344,
        "m5a.4xlarge" => 0.688,
        "m5a.8xlarge" => 1.376,
        "m4.2xlarge" => 0.40,
        "m4.xlarge"  => 0.20,
        "m4.large" => 0.10,
        "r5.xlarge" => 0.252,
        "t2.medium" => 0.0464,
        "t2.micro" => 0.0116,
        "t3a.micro" => 0.0094,
        "c4.4xlarge" => 0.796,
        "c4.2xlarge" => 0.398,
        "c4.xlarge" => 0.199,
        "c5.xlarge" => 0.17,
        "c5.2xlarge" => 0.34,
        "c5.4xlarge" => 0.68,
        "c5.9xlarge" => 1.53,
        "r4.large" => 0.133,
        "r4.xlarge" => 0.266,
        "r4.2xlarge" => 0.532,
        "r5a.xlarge" => 0.226,
        "t3a.xlarge" => 0.1504,
      }
    end

    # @return <Hashed Array of Instances> with each hash key being keyed on the `owned` tag.
    def regroup_instances(instances)
      cluster_map = {}
      instances.each do |r|
        owned =   r.tags.select {|t| t['value'] == "owned" }
        if owned.count > 0
          rindex = owned.first['key'].split('kubernetes.io/cluster/')[-1]
        else
          rindex = "no_owner"
        end
        if cluster_map[rindex]
          cluster_map[rindex] << r
        else
          cluster_map[rindex] = [r]
        end
      end
      return cluster_map
    end

    # @instances <Array of unordered Instance obj>
    def summarize_instances(region, instances)
      summary = []
      amz = @amz
      jenkins = @jenkins
      cm = regroup_instances(instances)
      cm.each do | owned, inst_list |
        inst_list.each do | inst |
          inst_summary = {}
          # inst_summary[:inst_obj] = inst
          inst_summary[:region] = region
          inst_summary[:name]= amz.instance_name inst
          inst_summary[:type] = inst.data['instance_type']
          inst_summary[:uptime]= amz.instance_uptime inst
          inst_hourly_price = @amz_prices[inst_summary[:type]]
          cost = 0.0
          if inst_hourly_price.nil?
            inst_hourly_price = 0.0
            puts "##### WARNING, setting hourly price for '#{inst_summary[:type]}' to 0.0 because it's not known"
          end

          cost = inst_summary[:uptime] * inst_hourly_price
          inst_summary[:cost] = cost.round(2)
          inst_summary[:owned] = amz.instance_owned inst
          if inst_summary[:owned]
            inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = jenkins.get_jenkins_flexy_job_id(inst_summary[:owned])
          else
            inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = nil, nil
          end
          summary << inst_summary
        end
      end
      return summary
    end

    def get_summary(target_region: nil, options: nil)
      regions = amz.get_regions
      region_names =  regions.map {|r| r.region_name }
      aws_instances = {}
      threads = []
      regions.each do | region |
        if target_region
          # first check name is valid
          raise "Unsupported region '#{target_region}'" unless region_names.include? target_region
          region.region_name = target_region
        end
        aws = Amz_EC2.new(region: region.region_name)
        instances = aws.get_instances_by_status('running')
        aws_instances[region.region_name] = instances
        ##  XXX commnet out thread implmentation for now as it's flaky when when in jenkins
        # threads << Thread.new(Amz_EC2.new(region: region.region_name)) do |aws|
        #   instances = aws.get_instances_by_status('running')
        #   aws_instances[region.region_name] = instances
        #   break if target_region == region.region_name
        # end
        # quick exit loop to save some un-nessary queries if a target region is specified
        break if target_region
      end
      ##  XXX commnet out thread implmentation for now as it's flaky when when in jenkins
      #threads.each(&:join)
      grand_summary = []
      # total_cost = 0.0
      aws_instances.each do |region, inst_list|
        total_cost = 0.0
        summary = summarize_instances(region, inst_list)
        print_summary(summary) if inst_list.count > 0
        options.platform = "AWS #{region}"
        print_longlived_clusters(summary, options) if inst_list.count > 0
        summary.each { |s| total_cost += s[:cost]}
        # print "REGION: #{region} TOTAL: #{total_cost}\n"
        grand_summary << {platform: 'aws', region: region, inst_count: inst_list.count, total_cost: total_cost}
      end
      print_grand_summary(grand_summary)
    end

  end

  class GceSummary < InstanceSummary
    attr_accessor :gce, :gce_prices

    def initialize(jenkins: nil)
      @gce = GCE.new
      @jenkins = jenkins
      @gce_prices = {
        # standard machine types
        "n1-standard-1" => 0.07,
        "n1-standard-2" => 0.14,
        "n1-standard-4" => 0.28,
        "n1-standard-8" => 0.56,
        "n1-standard-16" => 1.12,
        # shared-core machine types
        "f1-micro	" => 0.013,
        "g1-small" => 0.035,
        # High memory machine types
        "n1-highmem-2" => 0.164,
        "n1-highmem-4" => 0.328,
        "n1-highmem-8" => 0.656,
        "n1-highmem-16" => 1.312,
        # high cpu machines
        "n1-highcpu-2" => 0.088,
        "n1-highcpu-4" => 0.176,
        "n1-highcpu-8" => 0.352,
        "n1-highcpu-16" => 0.704,


      }
    end

    # for GCE, group the instance by network
    def regroup_instances(instances)
      cluster_map = {}

      instances.each do |inst|
        rindex = inst.network_interfaces.first.network.split('/').last
        if cluster_map[rindex]
          cluster_map[rindex] << inst
        else
          cluster_map[rindex] = [inst]
        end
      end
      return cluster_map
    end

    # @return <Array of Hash of summary>
    def summarize_instances(region, instance_list)
      summary = []
      gce = @gce
      project = gce.config[:project]
      jenkins = @jenkins
      cm = regroup_instances(instance_list)
      cm.each do | network, inst_list |
        inst_list.each do | inst |
          inst_summary = {}
          inst_summary[:region] = region
          inst_summary[:name]= inst.name
          inst_summary[:uptime]= gce.instance_uptime inst
          inst_summary[:type] = inst.machine_type.split('/').last
          inst_hourly_price = @gce_prices[inst_summary[:type]]
          cost = 0.0
          if inst_hourly_price.nil?
            inst_hourly_price = 0.0
            puts "##### WARNING, setting hourly price for '#{inst_summary[:type]}' to 0.0 because it's not known"
          end
          cost = inst_summary[:uptime] * inst_hourly_price
          inst_summary[:cost] = cost.round(2)
          inst_summary[:owned] = inst.name
          if inst_summary[:owned]
            inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = jenkins.get_jenkins_flexy_job_id(inst_summary[:owned])
          else
            inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = nil, nil
          end
          summary << inst_summary
        end
      end
      return summary
    end

    def get_summary(target_region: nil, options: nil)
      regions = gce.regions
      gce_instances = {}
      grand_summary = []
      targets = {}
      threads_zones = []

      if target_region
        targets[target_region] = regions[target_region]
      else
        targets = regions
      end

      targets.each do | region, zones |
        gce_instances[region] = []
        zone_threads = zones.each do |zone|
          threads_zones << Thread.new(zone) do |z|
            instances = gce.get_instances_by_status(zone: z, status: 'running')
            if instances
              instances.each do |inst|
                gce_instances[region] << inst
              end
            end
          end
        end
      end
      threads_zones.each(&:join)

      targets.each do |region, zones|
        # print "Getting summary for region #{region}\n"
        if gce_instances.keys.include? region
          summary = summarize_instances(region, gce_instances[region])
          total_cost = 0.0
          if summary.count > 0
            summary.each { |s| total_cost += s[:cost]}
            print_summary(summary)
          end
          grand_summary << {platform: 'gce', region: region, inst_count: summary.count, total_cost: total_cost}
          options.platform = "GCE"
          print_longlived_clusters(summary, options) if summary.count > 0
        end
      end
      print_grand_summary(grand_summary)
    end
  end

  class AzureSummary < InstanceSummary
    attr_accessor :azure, :azure_prices

    def initialize(jenkins: nil)
      @azure = Azure.new
      @jenkins = jenkins
      @azure_prices = {
        "Standard_DS1_v2" => 0.07,
        "Standard_D2s_v3" => 0.117,
        "Standard_D4s_v3" => 0.234,
        "Standard_D8s_v3" => 0.468,
      }
    end

    def summarize_instances(cm)
      summary = []
      cm.each do |rg_name, instances|
        instances.each do |inst|
          inst_summary = {}
          inst_summary[:region] = inst[:inst].location
          inst_summary[:name]= inst[:inst].name
          inst_summary[:uptime]= inst[:uptime]
          inst_summary[:type] = inst[:inst].hardware_profile.vm_size
          inst_summary[:cost] = (inst_summary[:uptime] * @azure_prices[inst_summary[:type]]).round(2)
          inst_summary[:owned] = rg_name.downcase
          if inst_summary[:owned]
            inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = jenkins.get_jenkins_flexy_job_id(inst_summary[:owned])
          else
            inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = nil, nil
          end
          summary << inst_summary
        end
      end
      return summary
    end

    def get_summary(options: nil)
      grand_summary = []
      # default status is 'PowerState/Running'
      # cluster_map keyed off by resource_group_name
      cm = azure.get_running_instances
      summary = summarize_instances(cm)
      total_cost = 0.0
      if summary.count > 0
        summary.each { |s| total_cost += s[:cost]}
        print_summary(summary)
      end

      options.platform = "Azure"
      print_longlived_clusters(summary, options) if summary.count > 0
      grand_summary << {platform: 'azure', region: summary.first[:region], inst_count: summary.count, total_cost: total_cost}
      print_grand_summary(grand_summary)
    end
  end


  class OpenstackSummary < InstanceSummary
    attr_accessor :os

    def initialize(jenkins: nil)
      @os = OpenStack.new
      @jenkins = jenkins
    end

    # instances is <Array> of server objects
    def summarize_instances(instances)
      summary = []
      sorted_instances = instances.sort_by {|k, v| k}.to_h
      sorted_instances.each do |name, inst|
        inst_summary = {}
        inst_summary[:region] = 'openstack'
        inst_summary[:name]= name
        inst_summary[:uptime]= os.instance_uptime inst["created"]
        inst_summary[:owned] =  name
        inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = jenkins.get_jenkins_flexy_job_id(name)
        summary << inst_summary
      end
      return summary
    end

    def get_summary(options: nil)
      grand_summary = []
      inst_details = os.get_running_instances
      # sleep 15
      summary = summarize_instances(inst_details)
        # summary = summarize_instances(rg_name, instances)
      print_summary(summary) if summary.count > 0
      options.platform = "Openstack"
      print_longlived_clusters(summary, options) if summary.count > 0
      grand_summary << {platform: 'openstack', region: summary.first[:region], inst_count: summary.count}
      print_grand_summary(grand_summary)
    end
  end

  class PacketSummary < InstanceSummary
    attr_accessor :packet, :packet_prices

    def initialize(jenkins: nil)
      @packet = Packet.new
      @jenkins = jenkins
      # https://metal.equinix.com/product/servers/ for pricing
      @packet_prices = {
        "t1.small.x86" => 0.07,
        "c2.medium.x86" => 1.10,
        "c3.small.x86" => 0.50,
        "c3.medium.x86" => 1.10,
        "m3.large.x86" => 2.00,
        "s3.xlarge.x86" => 1.85,
        "n2.xlarge.x86" => 2.25,
      }
    end

    # instances is <Array> of server objects
    def summarize_instances(instances)
      summary = []
      instances.each do | inst |
        inst_summary = {}
        inst_summary[:region] = 'packet'
        inst_summary[:name]= inst['hostname']
        inst_summary[:uptime]= packet.instance_uptime inst["created_at"]
        inst_summary[:type] = inst['plan']['name']
        inst_summary[:cost] = (inst_summary[:uptime] * @packet_prices[inst_summary[:type]]).round(2)
        inst_summary[:owned] = inst['created_by']['email']
        inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = jenkins.get_jenkins_flexy_job_id(inst['hostname'])
        summary << inst_summary
      end
      return summary
    end

    def get_summary(options: nil)
      grand_summary = []
      inst_details = packet.get_running_instances
      summary = summarize_instances(inst_details)
      total_cost = 0.0

      if summary.count > 0
        summary.each { |s| total_cost += s[:cost]}
        print_summary(summary)
      end

      options.platform = "Packet"
      print_longlived_clusters(summary, options) if summary.count > 0
      grand_summary << {platform: 'Packet', region: summary.first[:region], inst_count: summary.count, total_cost: total_cost}
      print_grand_summary(grand_summary)
    end
  end


  class VSphereSummary < InstanceSummary
    attr_accessor :vms

    def initialize(profile_name="vsphere_vmc7-qe", jenkins: nil)
      @vms = BushSlicer::VSphere.new(service_name: profile_name)
      @jenkins = jenkins
    end

    # instances is <Array> of server objects
    def summarize_instances(instances)
      summary = []
      instances.each do | inst |
        inst_summary = {}
        inst_summary[:region] = 'vSphere'
        inst_summary[:name]= inst['name']
        # group them by Folder name
        inst_summary[:owned] = inst.path[-2][1]
        inst_summary[:uptime]= vms.instance_uptime(inst.config.createDate)
        inst_summary[:flexy_job_id], inst_summary[:inst_prefix] = jenkins.get_jenkins_flexy_job_id(inst['name'])
        # overwrite it with Folder name
        inst_summary[:inst_prefix] = inst_summary[:owned]
        summary << inst_summary
      end
      return summary
    end

    def get_summary(options: nil)
      grand_summary = []
      machines = vms.get_running_instances
      inst_details = machines.select { |i| i.network.first.name == 'qe-segment' or i.network.first.name == 'discon-segment' }
      summary = summarize_instances(inst_details)
      print_summary(summary) if summary.count > 0
      options.platform = "VSphere"
      print_longlived_clusters(summary, options) if summary.count > 0
      grand_summary << {platform: 'vSphere', region: summary.first[:region], inst_count: summary.count}
      print_grand_summary(grand_summary)
    end
  end
end

