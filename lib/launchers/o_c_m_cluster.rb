#!/usr/bin/env ruby

lib_path = File.expand_path(File.dirname(File.dirname(__FILE__)))
unless $LOAD_PATH.any? {|p| File.expand_path(p) == lib_path}
  $LOAD_PATH.unshift(lib_path)
end

require 'common'
require 'json'
require 'yaml'
require 'tmpdir'
require 'git'
require 'os'
require 'cucuhttp'

module BushSlicer
  class OCMCluster
    include Common::Helper

    attr_reader :config, :ocm_cli
    attr_reader :token, :token_file, :url, :region, :version, :num_nodes, :lifespan, :cloud, :cloud_opts, :multi_az, :aws_account_id, :aws_access_key, :aws_secret_key

    def initialize(**options)
      service_name = ENV['OCM_SERVICE_NAME'] || options[:service_name] || 'ocm'
      @opts = default_opts(service_name)&.merge options
      unless @opts
        @opts = options
      end

      # OCM token is mandatory
      # it can be defined by token or by token_file
      @token = ENV['OCM_TOKEN'] || @opts[:token]
      @token_file = @opts[:token_file]
      unless @token
        if @token_file
          token_file_path = expand_private_path(@token_file)
          @token = File.read(token_file_path)
        else
          raise "You need to specify OCM token by 'token' or by 'token_file'"
        end
      end

      # region is mandatory
      # in the future we can extend support for other clouds, e.g. GCP and ARO
      @region = ENV['OCM_REGION'] || ENV['AWS_REGION'] || @opts[:region]

      # url defines the OCM environment (prod, integration or stage)
      # currently, the url is ignored as many teams use the stage environment
      @url = ENV['OCM_URL'] || @opts[:url] || 'https://api.stage.openshift.com'

      # openshift version is optional
      @version = ENV['OCM_VERSION'] || ENV['OCP_VERSION'] || @opts[:version]

      # number of worker nodes
      # minimum is 2
      # default value is 4
      @num_nodes = ENV['OCM_NUM_NODES'] || @opts[:num_nodes]

      # lifespan in hours
      # default value is 24 hours
      @lifespan = ENV['OCM_LIFESPAN'] || @opts[:lifespan]

      # multi_az is optional
      # default value is false
      @multi_az = ENV['OCM_MULTI_AZ'] || @opts[:multi_az]

      # BYOC (Bring Your Own Cloud)
      # you can refer to already defined cloud in config.yaml
      # currently, only AWS is supported
      if ENV['AWS_ACCOUNT_ID'] && ENV['AWS_ACCESS_KEY'] && (ENV['AWS_SECRET_ACCESS_KEY'] || ENV['AWS_SECRET_KEY'])
        # account_id will not be required once the following issue is fixed
        # https://github.com/openshift-online/ocm-cli/issues/216
        @aws_account_id = ENV['AWS_ACCOUNT_ID']
        @aws_access_key = ENV['AWS_ACCESS_KEY']
        @aws_secret_key = ENV['AWS_SECRET_ACCESS_KEY'] || ENV['AWS_SECRET_KEY']
      else
        @cloud = ENV['OCM_CLOUD'] || @opts[:cloud]
        if @cloud
          @cloud_opts = default_opts(@cloud)
          unless @cloud_opts
            raise "Cannot find cloud '#{cloud}' defined in '#{service_name}'"
          end
          case @cloud_opts[:cloud_type]
          when "aws"
            aws = Amz_EC2.new(service_name: @cloud)
            @aws_account_id = aws.account_id
            @aws_access_key = aws.access_key
            @aws_secret_key = aws.secret_key
          end
        end
      end
    end

    # @param service_name [String] the service name of this openstack instance
    #   to lookup in configuration
    def default_opts(service_name)
      return  conf[:services, service_name.to_sym]
    end

    private :default_opts

    def to_seconds(string)
      regex_m = /^(\d+)\s*(m|min|minutes|mins)+$/
      regex_h = /^(\d+)\s*(h|hour|hours|hrs)+$/
      regex_d = /^(\d+)\s*(d|day|days)+$/
      regex_w = /^(\d+)\s*(w|week|weeks|wks)+$/
      case string
      when regex_m
        return string.match(regex_m)[1].to_i * 60
      when regex_h
        return string.match(regex_h)[1].to_i * 60 * 60
      when regex_d
        return string.match(regex_d)[1].to_i * 24 * 60 * 60
      when regex_w
        return string.match(regex_w)[1].to_i * 7 * 24 * 60 * 60
      else
        raise "Cannot convert '#{string}' to seconds!"
      end
    end

    # Generate a cluster data used for creating OSD cluster
    def generate_cluster_data(name)
      json_data = {
        "name" => name,
        "managed" => true,
        "multi_az" => false,
        "ccs" => {
          "enabled": false
        }
      }

      if @multi_az
        json_data.merge!({"multi_az" => @multi_az})
      end

      if @region
        json_data.merge!({"region" => {"id" => @region}})
      end

      if @version
        json_data.merge!({"version" => {"id" => "openshift-v#{@version}"}})
      end

      if @num_nodes
        json_data.merge!({"nodes" => {"compute" => @num_nodes.to_i}})
      end

      if @lifespan
        expiration = Time.now + to_seconds(@lifespan)
        json_data.merge!({"expiration_timestamp" => expiration.strftime("%Y-%m-%dT%H:%M:%SZ")})
      end

      if @aws_account_id && @aws_access_key && @aws_secret_key
        json_data.merge!({"aws" => {"account_id":@aws_account_id, "access_key_id":@aws_access_key, "secret_access_key":@aws_secret_key}})
        json_data.merge!({"ccs" => {"enabled": true}})
      end

      return json_data
    end

    def download_ocm_cli
      url = ENV['OCM_CLI_URL']
      unless url
        url_prefix = ENV['OCM_CLI_URL_PREFIX'] || 'https://github.com/openshift-online/ocm-cli/releases/download/v0.1.46'
        if OS.mac?
          url = "#{url_prefix}/ocm-darwin-amd64"
        elsif OS.linux?
          url = "#{url_prefix}/ocm-linux-amd64"
        else
          raise "Unsupported OS"
        end
      end
      ocm_path = File.join(Host.localhost.workdir, 'ocm')
      File.open(ocm_path, 'wb') do |file|
        @result = Http.get(url: url, raise_on_error: true) do |chunk|
          file.write chunk
        end
      end
      File.chmod(0775, ocm_path)
      return ocm_path
    end

    def shell(cmd, output = nil)
      if output
        res = Host.localhost.exec(cmd, single: true, stderr: :stdout, stdout: output, timeout: 3600)
      else
        res = Host.localhost.exec(cmd, single: true, timeout: 3600)
      end
      if res[:success]
        return res[:response]
      else
        raise "Error when executing '#{cmd}'. Response: #{res[:response]}"
      end
    end

    def exec(cmd)
      unless @ocm_cli
        @ocm_cli = download_ocm_cli
      end
      return shell("#{@ocm_cli} #{cmd}").strip
    end

    def login
      ocm_token_file = Tempfile.new("ocm-token", Host.localhost.workdir)
      File.write(ocm_token_file, @token)
      exec("login --url=#{@url} --token=$(cat #{ocm_token_file.path})")
    end

    def get_value(osd_name, attribute)
      result = exec("list clusters --parameter search=\"name='#{osd_name}'\" --columns #{attribute}")
      return result.lines.last
    end

    def get_credentials(osd_name)
      osd_id = get_value(osd_name, "id")
      return JSON.parse(exec("get /api/clusters_mgmt/v1/clusters/#{osd_id}/credentials"))
    end

    # generate OCP information
    def generate_ocpinfo_data(api_url, user, password)
      host = URI.parse(api_url).host
      if host
        host = host.gsub(/^api\./, '')
      else
        raise "Given API url '#{api_url}' cannot be parsed"
      end
      ocp_info = {
        "ocp_domain" => host,
        "ocp_api_url" => "https://api.#{host}:6443",
        "ocp_console_url" => "https://console-openshift-console.apps.#{host}",
        "user" => user,
        "password" => password
      }
      return ocp_info
    end

    # create workdir/install-dir
    def create_install_dir
      install_dir = File.join(Host.localhost.workdir, 'install-dir')
      FileUtils.mkdir_p(install_dir)
      return install_dir
    end

    def create_cluster_file(osd_name, dir, filename = 'cluster.json')
      cluster_file = File.join(dir, filename)
      cluster_data = generate_cluster_data(osd_name)
      File.write(cluster_file, cluster_data.to_json)
      return cluster_file
    end

    def create_ocpinfo_file(osd_name, dir, filename = 'OCPINFO.yml')
      api_url = get_value(osd_name, "api.url")
      osd_id = get_value(osd_name, "id")
      ocp_creds = get_credentials(osd_name)
      user = ocp_creds["admin"]["user"]
      password = ocp_creds["admin"]["password"]
      ocpinfo_file = File.join(dir, filename)
      ocpinfo_data = generate_ocpinfo_data(api_url, user, password)
      File.write(ocpinfo_file, ocpinfo_data.to_yaml)
      return ocpinfo_file
    end

    # Wait until OSD cluster is ready and OCP version is available
    # NOTE: we need to wait for registering all metrics - OCP version indicates this state
    def wait_for_osd(osd_name)
      ocp_version = "NONE"
      loop do
        osd_status = get_value(osd_name, "state")
        logger.info("Status of cluster #{osd_name} is #{osd_status} and OCP version is #{ocp_version}")
        if osd_status == "ready"
          if ENV["OCM_WAIT_FOR_METRICS"] == "false"
            logger.info("Status of cluster #{osd_name} is #{osd_status} and we do not wait for metrics")
            break
          end
          ocp_version = get_value(osd_name, "openshift_version")
          if ocp_version != "NONE"
            break
          end
        end
        logger.info("Check again after 2 minutes")
        sleep(120)
      end
    end

    # Create OSD cluster
    def create_osd(osd_name)
      login
      install_dir = create_install_dir
      cluster_file = create_cluster_file(osd_name, install_dir)
      exec("post /api/clusters_mgmt/v1/clusters --body='#{cluster_file}'")
      wait_for_osd(osd_name)
      create_ocpinfo_file(osd_name, install_dir)
    end

    # delete OSD cluster
    def delete_osd(osd_name)
      login
      osd_id = get_value(osd_name, "id")
      exec("delete /api/clusters_mgmt/v1/clusters/#{osd_id}")
    end

  end

end
