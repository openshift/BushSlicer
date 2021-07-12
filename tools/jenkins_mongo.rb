require 'mongo'

# Turn off debug-mode
Mongo::Logger.logger.level = Logger::WARN

module BushSlicer
  class JenkinsMongo
    include Common::Helper
    attr_accessor :client, :collections, :query_results

    def initialize
      connect_opts = conf.dig('services', :mongodb, :host_connect_opts)
      #connect_opts = conf['services'][:mongodb][:host_connect_opts]
      host = connect_opts[:hostname]
      client_host = [host]
      client_options = {
        database: connect_opts[:db_name],
        user: connect_opts[:username],
        password: connect_opts[:password]
      }
      @client = Mongo::Client.new(client_host, client_options)
      @collections = @client[connect_opts[:db_name]]
    end

    def insert_data(data)
      self.collections.update_one(data, {'$set'=> data}, {:upsert => true})
    end

    # find a document with job_name & job_id match and remove it
    def remove_document(data)
      self.collections.find(data).delete_many
    end

    def get_all_builds(query: nil)
      query ||= {}
      @query_results = self.collections.find(query).to_a
    end

    def construct_build_map
      # query = {"result"=> "SUCCESS"}
      query = {}
      build_map = {}
      build_owner_map = {}
      builds = self.get_all_builds(query: query)
      builds.map do |b|
        build_map[b["instance_prefix"]] = b['job_id']
        if b.has_key? 'user'
          # users installed by Flexy-install has the format  <username-job-id>
          # we just want the username.
          build_owner_map[b['job_id']] = b['user'].split('-').first
        end
      end
      # build_map.keys.compact!
      sorted_keys = build_map.keys.compact!.sort
      return build_map, sorted_keys, build_owner_map
    end

  end

end

if __FILE__ == $0
  m = BushSlicer::JenkinsMongo.new
end
