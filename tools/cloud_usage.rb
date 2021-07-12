#!/usr/bin/env ruby
$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")
$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../tools")

"""
Helper utility to interact with AWS services on the command-line
"""

require 'commander'

require 'launchers/amz'

require 'collections'
require 'common'
require 'cucuhttp'
require 'thread'
require 'jenkins_api_client'
require 'text-table'
# GCE specific
require 'google/apis/compute_v1'
require 'googleauth'
require 'launchers/openstack'
# user libs
require 'instance_summary'
require 'jenkins'
require 'jenkins_mongo'
require 'iam_summary'
require 'pry-byebug'
module BushSlicer
  class CloudUsage
    include Commander::Methods
    include Common::Helper
    include Common::CloudHelper
    attr_accessor :jenkins, :build_map, :bm_sorted_keys, :build_user_map, :amz, :gce, :azure
    # TODO: perhaps we can cache the jenkins id mapping into a db instead to
    # to save time
    def initialize
      @jenkins = Jenkins.new
      @mongodb = JenkinsMongo.new
      @jenkins.build_map, @jenkins.bm_sorted_keys, @jenkins.build_user_map = @mongodb.construct_build_map
      @jenkins.construct_jenkins_build_map unless @jenkins.build_map
      always_trace!
    end

    def run
      program :name, 'CloudUsage'
      program :version, '0.0.1'
      program :description, 'Helper utility to display summary of running instances in supported cloud platforms'
      global_option('--no_slack') do |f|
        no_slack = true
      end
      default_command :help

      command :"aws" do |c|
        c.syntax = "#{File.basename __FILE__} -r <aws_region_name> [--all]"
        c.description = 'display summary of running instances'
        c.option("-r", "--region region_name", "report on this region only")
        c.option("-u", "--uptime cluter uptime limit", "report for clusters having uptime over this limit")
        c.action do |args, options|
          ps = AwsSummary.new(jenkins: @jenkins)
          options.config = conf
          say 'Getting summary...'
          ps.get_summary(target_region: options.region, options: options)

        end
      end

      command :"gce" do |c|
        c.syntax = "#{File.basename __FILE__} -r <gce_region_name> [--all]"
        c.description = 'display summary of running instances'
        c.option("-r", "--region region_name", "report on this region only")
        c.option("-u", "--uptime cluter uptime limit", "report for clusters having uptime over this limit")
        c.action do |args, options|
          ps = GceSummary.new(jenkins: @jenkins)
          options.config = conf
          ps.get_summary(target_region: options.region, options: options)
        end
      end
      command :"azure" do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display summary of running instances'
        c.option("-u", "--uptime cluter uptime limit", "report for clusters having uptime over this limit")
        c.action do |args, options|
          ps = AzureSummary.new(jenkins: @jenkins)
          options.config = conf
          ps.get_summary(options: options)
        end
      end
      # internal openstack
      command :"openstack" do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display summary of running instances'
        c.option("-u", "--uptime cluter uptime limit", "report for clusters having uptime over this limit")
        c.action do |args, options|
          ps = OpenstackSummary.new(jenkins: @jenkins)
          options.config = conf
          ps.get_summary(options: options)
        end
      end
      # packet
      command :"packet" do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display summary of running instances'
        c.option("-u", "--uptime cluter uptime limit", "report for clusters having uptime over this limit")
        c.action do |args, options|
          ps = PacketSummary.new(jenkins: @jenkins)
          options.config = conf
          ps.get_summary(options: options)
        end
      end
      # VSphere
      command :"vsphere" do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display summary of running instances'
        c.option("-u", "--uptime cluter uptime limit", "report for clusters having uptime over this limit")
        c.action do |args, options|
          vms = VSphereSummary.new(jenkins: @jenkins)
          options.config = conf
          vms.get_summary(options: options)
        end
      end

      # Display IAMs for aws
      command :"aws_iams" do |c|
        c.syntax = "#{File.basename __FILE__}"
        c.description = 'display summary of IAMs'
        c.action do |args, options|
          ps = IAM_AwsSummary.new
          options.config = conf
          say 'Getting IAM summary...'
          ps.get_summary(options: options)

        end
      end
      run!
    end
  end
end

if __FILE__ == $0
  BushSlicer::CloudUsage.new.run
end
