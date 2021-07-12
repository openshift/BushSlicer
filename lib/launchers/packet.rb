

lib_path = File.expand_path(File.dirname(File.dirname(__FILE__)))
unless $LOAD_PATH.any? {|p| File.expand_path(p) == lib_path}
  $LOAD_PATH.unshift(lib_path)
end

require 'collections'
require 'common'

module BushSlicer
  class Packet
    include Common::Helper
    include CollectionsIncl
    attr_reader :config

    def initialize(**opts)
      @config = conf[:services, opts.delete(:service_name) || :packet]
    end
    # @return [ResultHash]
    # @yield [req_result] if block is given, it is yielded with the result as
    #   param
    def rest_run(url, method, params, token = nil, read_timeout = 60, open_timeout = 60)
      headers = {'Content-Type' => 'application/json',
                 'Accept' => 'application/json'}
      headers['X-Auth-Token'] = token if token

      req_opts = {
          :url => "#{url}",
          :method => method,
          :headers => headers,
          :read_timeout => read_timeout,
          :open_timeout => open_timeout
      }
      # if opts.has_key? :proxy
      #   req_opts[:proxy] = opts[:proxy]
      # end

      case method
      when "GET", "DELETE"
        req_opts[:params] = params
      else
        if headers["Content-Type"].include?("json") &&
            ( params.kind_of?(Hash) || params.kind_of?(Array) )
          params = params.to_json
        end
        req_opts[:payload] = params
      end

      res = Http.request(**req_opts)

      if res[:success]
        if res[:headers] && res[:headers]['content-type']
          content_type = res[:headers]['content-type'][0]
          case
          when content_type.include?('json')
            res[:parsed] = YAML.load(res[:response])
          when content_type.include?('yaml')
            res[:parsed] = YAML.load(res[:response])
          end
        end

        yield res if block_given?
      end
      return res
    end

    def get_running_instances()
      params ||= {}
      url = self.config[:api_url] + '/projects/' + self.config[:project_id] + '/devices?include=facility'
      res = self.rest_run(url, "GET", params, self.config[:auth_token])
      raise "Failed to get running packet instances..." unless res[:success]
      res[:parsed]['devices']
    end

    # current time - creation time
    def instance_uptime(timestamp)
      ((Time.now  - Time.parse(timestamp)) /(60 * 60)).round(2)
    end
  end
end
