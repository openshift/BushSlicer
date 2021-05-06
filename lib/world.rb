require 'ostruct'
require 'common'
require 'collections'

module BushSlicer
  # @note this is our default cucumber World extension implementation
  class DefaultWorld
    include CollectionsIncl
    include Common::Helper
    include Common::Hacks

    attr_accessor :scenario

    def initialize
      # we want to keep a reference to current World in the manager
      # hopefully cucumber does not instantiate us too early
      manager.world = self

      @clipboard = OpenStruct.new
      @browsers = []
      @bg_processes = []
      @bg_rulesresults = []

      # some arrays to store cached projects as they have a custom getter
      @projects = []
      # used to store host the user wants to run commands on
      @host = nil
      # procs and lambdas to call on clean-up
      @teardown = []
    end

    # shorthand accessor for @clipboard
    def cb
      return @clipboard
    end

    def setup_logger
      BushSlicer::Logger.runtime = self
    end

    def debug_in_after_hook?
      scenario.failed? && conf[:debug_in_after_hook] || conf[:debug_in_after_hook_always]
    end

    def debug_in_after_hook
      if debug_in_after_hook?
        require 'pry'
        binding.pry
        fix_require_lock # see method in Common::Hacks
      end
    end

    def scenario_tags
      scenario.source_tag_names
    end

    def tagged_admin?
      scenario_tags.include? '@admin'
    end

    def tagged_destructive?
      scenario_tags.include? '@destructive'
    end

    def tagged_upgrade?
      scenario_tags.include? '@upgrade-prepare' || (scenario_tags.include? '@upgrade-check')
    end

    def tagged_upgrade_check?
      scenario_tags.include? '@upgrade-check'
    end

    def tagged_upgrade_prepare?
      scenario_tags.include? '@upgrade-prepare'
    end

    def ensure_admin_tagged
      raise 'tag scenario @admin as you use admin access' unless tagged_admin?
    end

    def ensure_destructive_tagged
      raise 'tag scenario @admin and @destructive as you use admin access and failure to restore can have adverse effects to following scenarios' unless tagged_admin? && tagged_destructive?
    end

    def ensure_upgrade_tagged
      raise 'tag scenario @upgrade-prepare or @upgrade-check as you update cluster without teardown' unless tagged_upgrade?
    end

    def ensure_upgrade_check_tagged
      raise 'tag scenario @upgrade-check as you update cluster without teardown' unless tagged_upgrade_check?
    end

    def ensure_upgrade_prepare_tagged
      raise 'tag scenario @upgrade-prepare as you update cluster without teardown' unless tagged_upgrade_prepare?
    end

    # prepares environments' user managers based on @users tag
    # @return [Object] undefined
    # @note tags might not be present for each env thus #prepare might not be
    #   called on each user manager; this is ok because `#prepare(nil)` over
    #   a *clean* user manager should not affect its (in)ability to work
    def prepare_scenario_users
      scenario_tags.select{|t| t.start_with? "@users"}.each do |userstag|
        tagname, tagvalue = userstag.split("=", 2)
        unless tagvalue && !tagvalue.empty?
          raise "users tag value should not be nil or empty"
        end

        garbage, env_name = tagname.split(":", 2)
        env_name ||= conf[:default_environment]
        manager.environments[env_name].user_manager.prepare(tagvalue)
      end
    end

    # @note call like `env(:key)` or simply `env` for current environment
    def env(key=nil)
      return @env if key.nil? && @env
      key ||= conf[:default_environment]
      raise "please specify default environment key in config or BUSHSLICER_DEFAULT_ENVIRONMENT env variable" unless key
      return @env = manager.environments[key]
    end

    def admin
      env.admin
    end

    def host
      return @host
    end

    ## generate Resource getters
    # @return openshift resource by name from scenario cache; with no params given,
    #   returns last requested resource of this type; otherwise creates a new resource object
    # @see #project_resource
    # @see #cluster_resource
    # @note you need the project already created
    RESOURCES.each do |clazz, snake_case|
      if clazz < ProjectResource
        eval <<-"END_EVAL", binding, __FILE__, __LINE__ + 1
          def #{snake_case}(*args, &block)
            project_resource(#{clazz}, *args, &block)
          end
        END_EVAL
      elsif clazz < ClusterResource
        eval <<-"END_EVAL", binding, __FILE__, __LINE__ + 1
          def #{snake_case}(*args, &block)
            cluster_resource(#{clazz}, *args, &block)
          end
        END_EVAL
      else
        raise "don't know how to create getter for #{clazz.name}"
      end
    end

    alias bc build_config
    alias dc deployment_config
    alias hpa horizontal_pod_autoscaler
    alias istag image_stream_tag
    alias netns net_namespace
    alias opsrc operator_source
    alias psp pod_security_policy
    alias pv persistent_volume
    alias pvc persistent_volume_claim
    alias rc replication_controller
    alias rs replica_set
    alias scc security_context_constraints
    alias kubeapiserver kube_a_p_i_server
    alias openshiftapiserver open_shift_a_p_i_server
    alias consolenotification console_notifications_console_openshift_io
    # @note call like `user(0)` or simply `user` for current user
    def user(num=nil, switch: true)
      return @user if num.nil? && @user
      num = 0 unless num
      @user = env.users[num] if switch
      return env.users[num]
    end

    # @return project from cached projects for this scenario
    #   note that you need to have default `#env` set already;
    #   if no name is spefified, returns the last requested project;
    #   otherwise a BushSlicer::Project object is created (but not created in
    #   the actual OpenShift environment)
    # @note we use a custom getter instead of auto-generated resource getters
    #   to allow generating project names; maybe that can be refactored some day
    def project(name = nil, env: nil, generate: false, switch: true)
      env ||= self.env
      if name.kind_of? Integer
        p = @projects[name]
        raise "no project cached with index #{name}" unless p
        @projects << @projects.delete(p) if switch
        return p
      elsif name
        p = @projects.find {|p| p.name == name && p.env == env}
        if p && @projects.last.equal?(p)
          return p
        elsif p
          # put requested project at top of the stack
          @projects << @projects.delete(p) if switch
          return p
        else
          method = switch ? :push : :unshift
          requested_project = Project.new(name: name, env: env)
          @projects.send method, requested_project
          return requested_project
        end
      elsif @projects.empty?
        if generate
          @projects << Project.new(name: rand_str(5, :dns), env: env)
          return @projects.last
        else
          raise "no projects in cache"
        end
      else
        return @projects.last
      end
    end

    # override to stay compatible with legacy Route code
    def route(name = nil, service_or_project = nil)
      case service_or_project
      when nil
        project = self.project
      when Project
        project = service_or_project
      when Service
        service = service_or_project
        project = service.project
      else
        raise "identify route by project or service"
      end

      return project_resource(Route, name, project)
    end

    # @param name [String] can be short or full service account name
    def service_account(name = nil, project = nil)
      if name && name.include?(":")
        m = name.match /^system:serviceaccount:([^:]+):([^:]+)$/
        if m
          if project && project.name != m[1]
            raise "project name and service account name do not match: " \
              "#{name} vs #{project.name}"
          end
          return project_resource(ServiceAccount, m[2], project(m[1]))
        else
          raise "bad service account name: #{name}"
        end
      else
        return project_resource(ServiceAccount, name, project)
      end
    end

    # @return web4cucumber object from scenario cache
    def browser(num = -1)
      num = Integer(num) rescue word_to_num(num)

      raise "no web browsers cached in World" if @browsers.empty?

      case
      when num > @browsers.size + 1 || num < -@browsers.size
        raise "web browsers index not found: #{num} for size #{@browsers.size}"
      else
        cache_browser(@browsers[num]) unless num == -1
        return @browsers.last
      end
    end

    # put the specified browser at top of our cache avoiding duplicates
    def cache_browser(browser)
      @browsers.delete(browser)
      @browsers << browser
    end

    # returns the cache array for the given resource class
    # @param clazz [Class] the resource class we are interested in
    private def resource_cache(clazz)
      var = "@#{clazz::RESOURCE}".tr(".","_")
      return instance_variable_get(var) || instance_variable_set(var, [])
    end

    # @param clazz [Class] class of project resource
    # @param name [String, Integer] string name or integer index in cache
    # @return [ProjectResource] by name from scenario cache or creates a new
    #   object with the given name; with no params given, returns last
    #   requested project resource of the clazz type; otherwise raises
    # @note you need the project already created
    def project_resource(clazz, name = nil, project = nil)
      project ||= self.project

      clazzname = clazz.shortclass
      cache = resource_cache(clazz)

      if Integer === name
        # using integer index does not trigger reorder of list
        return cache[name] || raise("no #{clazzname} with index #{name}")
      elsif name
        # using a string name, moves found resource to top of the list
        r = cache.find {|r| r.name == name && r.project == project}
        if r && cache.last == r
          return r
        elsif r
          cache << cache.delete(r)
          return r
        else
          # create new BushSlicer::ProjectResource object with specified name
          cache << clazz.new(name: name, project: project)
          cache.last.default_user = user
          return cache.last
        end
      elsif cache.empty?
        # do not create random project resource like with projects because that
        #   would rarely make sense
        raise "what #{clazzname} are you talking about?"
      else
        return cache.last
      end
    end

    # @param clazz [Class] class of cluster resource
    # @param name [String, Integer] string name or integer index in cache
    # @return [ClusterResource] by name from scenario cache or creates a new
    #   object with the given name; with no params given, returns last
    #   requested cluster resource of the clazz type; otherwise raises
    def cluster_resource(clazz, name = nil, env = nil, switch: nil)
      env ||= self.env

      clazzname = clazz.shortclass
      cache = resource_cache(clazz)

      if Integer === name
        # using integer index does not trigger reorder of list
        return cache[name] || raise("no #{clazzname} with index #{name}")
      elsif name
        switch = true if switch.nil?
        r = cache.find {|r| r.name == name && r.env == env}
        if r
          cache << cache.delete(r) if switch
          return r
        else
          # create new BushSlicer::ClusterResource object with specified name
          cache << clazz.new(name: name, env: env)
          return cache.last
        end
      elsif cache.empty?
        # we do not create a random PV like with projects because that
        #   would rarely make sense
        raise "what #{clazzname} are you talking about?"
      else
        return cache.last
      end
    end

    def cache_resources(*resources)
      resources.each do |res|
        cache = resource_cache(res.class)
        cache.delete(res)
        cache << res
      end
    end
    alias cache_pods cache_resources

    # tries to create resource off string name and type as used in REST API
    # e.g. resource("hello-openshift", "pod")
    def resource(name, type, project_name: nil)
      clazz = resource_class(type)

      subclass_of = proc {|parent, child| parent >= child}
      return case clazz
      when subclass_of.curry[ProjectResource]
        project_resource(clazz, name, project(project_name))
      when subclass_of.curry[ClusterResource]
        cluster_resource(clazz, name, env)
      else
        raise "unhandled class #{clazz}"
      end
    end

    # convert from resource cli string to BushSlicer class
    def resource_class(cli_string)
      unless @shorthands
        @shorthands = {
          crd: "customresourcedefinition",
          cs: "catalogsource",
          csv: "clusterserviceversion",
          dc: "deploymentconfigs",
          ds: "daemonsets",
          hpa: "horizontalpodautoscalers",
          is: "imagestreams",
          istag: "imagestreamtags",
          netns: "netnamespaces",
          opsrc: "operatorsources",
          csc: "catalogsourceconfigs",
          psp: "podsecuritypolicy",
          pv: "persistentvolumes",
          pvc: "persistentvolumeclaims",
          rc: "replicationcontrollers",
          rs: "replicasets",
          scc: "securitycontextconstraints",
          svc: "service",
          sc: "storageclass"
        }
        @shorthands.merge!(RESOURCES.map {|clazz, snake_case| [snake_case, clazz::RESOURCE]}.to_h)
      end

      type = @shorthands[cli_string.to_sym] || cli_string

      # classes = ObjectSpace.each_object(BushSlicer::Resource.singleton_class)
      # clazz = classes.find do |c|
      clazz = RESOURCES.keys.find do |c|
        defined?(c::RESOURCE) && [type, type + "s", type+"es"].include?(c::RESOURCE)
      end
      raise "cannot find class for type #{type}" unless clazz
      return clazz
    end

    # @param procs [Proc] a proc or lambda to add to teardown
    # @yield [] a block that will be added to teardown
    # @note teardowns should ever raise only if issue can break further
    #   scenario execution. When a teardown raises, that causes cucumber to
    #   skip executing any further scenarios.
    def teardown_add(*procs, &block)
      @teardown.concat procs
      if block
        @teardown << block
      end
    end

    # @param annotation [Object] some object to identify this teardown
    # @return undefined
    def teardown_annotate_last(annotation)
      b = @teardown.last.binding
      b.local_variable_set(:_teardown_annotation, annotation)
    end

    # @param annotation [Object] annotation we are looking for
    # @return [Proc, nil] the teardown with the specified annotation;
    #   where `===` is used to compare
    def teardown_find_annotated(annotation)
      @teardown.find { |p|
        b = p.binding
        b.local_variable_defined?(:_teardown_annotation) &&
          annotation === b.local_variable_get(:_teardown_annotation)
      }
    end

    def quit_cucumber
      logger.error "Test Execution will finish prematurely."
      Cucumber.wants_to_quit = true
    end

    def after_scenario
      # call all teardown lambdas and procs; see [#teardown_add]
      # run last registered teardown routines first
      @teardown.reverse_each { |f| f.call }
    end

    # @return the desired base docker image tag prefix based on
    #   PRODUCT_DOCKER_REPO env variable
    def product_docker_repo(environment = env)
      if ENV["PRODUCT_DOCKER_REPO"] &&
          !ENV["PRODUCT_DOCKER_REPO"].empty?
        ENV["PRODUCT_DOCKER_REPO"]
      elsif conf[:product_docker_repo]
        conf[:product_docker_repo]
      else
        environment.system_docker_repo
      end
    end

    def project_docker_repo
      conf[:project_docker_repo]
    end

    # transforms <%= expression %> inside variables of a target binding
    # it is safer not to modify the original strings and tables
    # @param [String, Cucumber::MultilineArgument::DataTable] x field to process
    # @return string with expanded evaluation of expressions
    def transform_value(x)
      if x.nil?
        nil
      elsif x.respond_to? :raw
        table( x.raw.map { |row| row.map { |cell| transform_value(cell) } } )
      elsif x.respond_to? :gsub
        x.gsub(/<%=(.+?)%>/m) { |c| eval $1 }
      elsif x.respond_to? :to_s
        x.to_s
      else
        raise ArgumentError, "Unexected argument: #{x.inspect}"
      end
    end

    def transform(target_binding, *variables)
      b = target_binding
      unless Binding === b
        raise ArgumentError, "First argument must be a Binding, instead it is #{b.inspect}"
      end
      variables.each do |v|
        b.local_variable_set(v, transform_value(b.local_variable_get(v)))
      end
    end

    # Embedded table delimiter is '!' if '|' not used
    # Gherkin more recent than 3.1.2 does support escaping new lines by `\n`.
    #   Also these two escapes are supported: `\|` amd `\\`. This means two
    #   things. First it is now possible to escape `|` in tables. And second is
    #   that clean-up steps with `\n` will most likely fail if written inside
    #   a table. To support `\n` in clean-up steps, I believe the table syntax
    #   should be used and table should be generated as `table(Array)`
    #   instead of table(String)
    # @param step_spec [#lines, #raw] steps string lines should be obtained
    #   by calling #lines method over spec or calling #raw.flatten; that is
    #   usually a multiline string or Cucumber::MultilineArgument::DataTable
    # @return [Array<Proc>] each step in a separate proc in *reverse* order
    def to_step_procs(steps_spec)
      if steps_spec.respond_to? :lines
        # multi-line string
        data = steps_spec.lines
      else
        # Cucumber Table
        data = steps_spec.raw.flatten
      end
      data.reject! {|l| l.empty? || l =~ /^.s*#/}

      step_list = []
      step_name = ''
      params = []
      data.each_with_index do |line, index|
        line = line.strip
        if line.start_with?('!')
          params << [line.gsub('!','|')]
        elsif line.start_with?('|')
          # with multiline string we can use '|' or it can be escaped
          params << line
        else
          step_name = line.gsub(/^\s*(?:Given|When|Then|And) /,"")
        end
        next_is_not_param = data[index+1].nil? ||
                            !data[index+1].strip.start_with?('!','|')
        if next_is_not_param
          raise "step not specified" if step_name.strip.empty?

          # then we should add the step to tierdown
          # But do it within a proc to have separately scoped variable for each step
          #   otherwise we end up with all lambdas using the same `step_name` and
          #   `params` variables. That means all lambdas defined within this step
          #   invocation, because lambdas and procs inherit binding context.
          #
          proc {
            _step_name = step_name
            if params.empty?
              step_list.unshift proc {
                logger.info("Step: " << _step_name)
                step _step_name
              }
            else
              _params = params.join("\n")
              step_list.unshift proc {
                logger.info("Step: #{_step_name}\n#{_params}")
                step _step_name, table(_params)
              }
            end
          }.call
          params = []
          step_name = ''
        end
      end

      return step_list
    end
  end
end
