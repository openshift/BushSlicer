require 'text-table'
require 'thread'
require 'pry-byebug'

module BushSlicer
  class IAM_Summary
    def initialize
      puts "*****\n"
    end

    def uptime(create_time)
      ((Time.now.utc - create_time) / (60 * 60)).round(2)
    end
  end

  class IAM_AwsSummary < IAM_Summary
    attr_accessor :amz, :raw_users
    def initialize
      @amz = Amz_EC2.new
    end
    # print out name of the IAM and uptime.  Only print those that have been alive for more than 102 hours/5days
    def print_filtered_raw_summary(threshold: 96)
      table = Text::Table.new

    end

    def instance_uptime(creation_time)
      ((Time.now.utc - creation_time) / (60 * 60)).round(2)
    end

    # input: per_page (default to 200), API defaults to 100 and max of 1000 per page
    # @return [Array] of IAM users
    def get_all_users(per_page: 500)
      users = []
      @amz.iam_client.list_users({max_items: per_page}).each do |response|
        # Get additional pages
        users << response.data[0]
        response = response.next_page until response.last_page?
      end
      all_users = users.flatten
      return all_users
    end

    def user_group_name(username: nil)
      unless self.amz.iam_client.list_groups_for_user(user_name: username).groups.first.nil?
        group_name = self.amz.iam_client.list_groups_for_user(user_name: username).groups.first.group_name
        puts "#{username}:  #{group_name}\n"
      end
      return group_name
    end

    def get_all_dev_or_admin_users(users: nil, creds: nil)
      @raw_users ||= self.get_all_users
      unless creds
        first_filter = users.select {|u| u.user_name unless u.user_name.include? '-'}
        dev_users = first_filter.select { |u|
          self.user_group_name(username: u.user_name) == 'Dev' or
          self.user_group_name(username: u.user_name) == 'Admin'
        }
        binding.pry
        print dev_users
      else
        dev_or_admin_users = YAML.load(open(File.expand_path(creds)))
        return dev_or_admin_users

      end

    end

    def group_iams_by_users(users: nil)
      user_map = {}
      user_map['unknown'] = []
      self.raw_users.each do |u|
        users.keys.select { |k|
          if k == u.user_name
            # skip if the user-key and current username is the same
            user_map[k] = []
          elsif u.user_name.include? k
            user_map[k] = [] if user_map[k].nil?
            user_map[k] << u
          else
            # no match, just break out and go onto the next one
            # put it into the `unknown` bucket
            next
            # puts "K: #{k}\n"
            # user_map[k] = [] if user_map[k].nil?
            # user_map[k] << u
          end
        }
      end
      total = 0
      user_map.each do |k, v|
        total += user_map[k].count
      end
      binding.pry
    end

    # 1. normal user names don't have `-` in them...so
    def get_summary(options: nil)
      krb_users = get_all_dev_or_admin_users(users: self.get_all_users, creds: "creds/aws_iam_users_map.yml")
      group_iams_by_users(users: krb_users)

      binding.pry
    end
    # print out all IAMs that are older than 5 days
    def filter_raw_users(uptime_limit: 120)
      @raw_users ||= self.get_all_users
      self.raw_users.each do |u|
        u.create_date
      end
    end
  end

  class IAM_GceSummary < IAM_Summary
    attr_accessor :gce

    def initialize
      @gce = GCE.new
    end

  end

  class IAM_AzureSummary < IAM_Summary
    attr_accessor :azure

    def initialize
      @azure = Azure.new
    end
  end



  class IAM_OpenstackSummary < IAM_Summary
    attr_accessor :os

    def initialize
      @os = OpenStack.new
    end
  end

  class IAM_PacketSummary < IAM_Summary
    attr_accessor :packet

    def initialize
      @packet = Packet.new
    end
  end

  class IAM_VSphereSummary < IAM_Summary
    attr_accessor :vms

    def initialize(profile_name="vsphere_vmc7-qe", jenkins: nil)
      @vms = BushSlicer::VSphere.new(service_name: profile_name)
    end
  end
end
