#!/usr/bin/ruby -w

# Imports within Ruby's standard libraries
require 'logger'
require 'monitor'
require 'net/http'
require 'net/https'
require 'openssl'
require 'socket'
require 'soap/rpc/driver'
require 'syslog'
require 'timeout'
require 'tmpdir'
require 'yaml'


# Imports for RubyGems
require 'rubygems'
require 'httparty'
require 'json'
require 'zookeeper'


# Imports for AppController libraries
$:.unshift File.join(File.dirname(__FILE__), "lib")
require 'app_controller_client'
require 'app_manager_client'
require 'backup_restore_service'
require 'blobstore'
require 'cron_helper'
require 'custom_exceptions'
require 'datastore_server'
require 'ejabberd'
require 'error_app'
require 'groomer_service'
require 'haproxy'
require 'helperfunctions'
require 'hermes_service'
require 'infrastructure_manager_client'
require 'monit_interface'
require 'nginx'
require 'search'
require 'taskqueue'
require 'taskqueue_client'
require 'terminate'
require 'user_app_client'
require 'zkinterface'
require "zookeeper_helper"

NO_OUTPUT = false

# This lock makes it so that global variables related to apps are not updated
# concurrently, preventing race conditions.
APPS_LOCK = Monitor.new()

# This lock is to ensure that only one thread is trying to start/stop
# applications.
AMS_LOCK = Mutex.new()

# A HTTP client that assumes that responses returned are JSON, and automatically
# loads them, returning the result. Raises a NoMethodError if the host/URL is
# down or otherwise unreachable.
class JSONClient
  include HTTParty

  # Assume the response is JSON and load it accordingly.
  parser(
    Proc.new do |body, format|
      JSON.load(body)
    end
  )
end


# The string that should be returned to the caller if they call a publicly
# exposed SOAP method but provide an incorrect secret.
BAD_SECRET_MSG = "false: bad secret"


# The String that should be returned to callers if they attempt to add or remove
# AppServers from an HAProxy config file at a node where HAProxy is not running.
NO_HAPROXY_PRESENT = "false: haproxy not running"


# The String that should be returned to callers if they attempt to add
# AppServers for an app that does not yet have nginx and haproxy set up.
NOT_READY = "false: not ready yet"


# A response that indicates that the caller made an invalid request.
INVALID_REQUEST = 'false: invalid request'


# Regular expression to determine if a file is a .tar.gz file.
TAR_GZ_REGEX = /\.tar\.gz$/


# The maximum number of seconds that we should wait when deploying Google App
# Engine applications via the AppController.
APP_UPLOAD_TIMEOUT = 180


# The location on the local file system where we store information about
# where ZooKeeper clients are located, used to backup and restore
# AppController information.
ZK_LOCATIONS_FILE = "/etc/appscale/zookeeper_locations.json"


# The location of the logrotate scripts.
LOGROTATE_DIR = '/etc/logrotate.d'


# The name of the generic appscale centralized app logrotate script.
APPSCALE_APP_LOGROTATE = 'appscale-app-logrotate.conf'


# Djinn (interchangeably known as 'the AppController') automatically
# configures and deploys all services for a single node. It relies on other
# Djinns or the AppScale Tools to tell it what services (roles) it should
# be hosting, and exposes these methods via a SOAP interface (as is provided
# in DjinnServer).
class Djinn
  # An Array of DjinnJobData objects, each of which containing information about
  # a node in the currently running AppScale deployment.
  attr_accessor :nodes


  # A Hash containing all the parameters needed to configure any service
  # on any node. At a minimum, this is all the information from the AppScale
  # Tools, including information about database parameters and the roles
  # for all nodes.
  attr_accessor :options


  # An Array of Strings, each of which corresponding to the name of an App
  # Engine app that should be loaded.
  attr_accessor :app_names


  # An Array of Strings, each of which corresponding to the name of an App
  # Engine app that has been loaded on this node.
  attr_accessor :apps_loaded


  # An Array of Strings, each of which corresponding to the name of an App
  # Engine app that should be restarted on this node.
  attr_accessor :apps_to_restart


  # A boolean that is used to let remote callers know when this AppController
  # is done initializing itself, but not necessarily done starting or
  # stopping roles.
  attr_accessor :done_initializing


  # A boolean that is used to let remote callers know when this AppController
  # is done starting all the services it is responsible for.
  attr_accessor :done_loading



  # The human-readable state that this AppController is in.
  attr_accessor :state


  # A boolean that is used to let remote callers start the shutdown process
  # on this AppController, which will cleanly shut down and terminate all
  # services on this node.
  attr_accessor :kill_sig_received


  # An Integer that indexes into @nodes, to return information about this node.
  attr_accessor :my_index


  # The number of dev_appservers that should run for every App Engine
  # application.
  attr_accessor :num_appengines



  # An Array that lists the CPU, disk, and memory usage of each machine in this
  # AppScale deployment. Used as a cache so that it does not need to be
  # generated in response to AppDashboard requests.
  attr_accessor :all_stats


  # An integer timestamp that corresponds to the last time this AppController
  # has updated @nodes, which we use to compare with a similar timestamp in
  # ZooKeeper to see when data in @nodes has changed on other nodes.
  attr_accessor :last_updated


  # A Hash that contains information about each Google App Engine application
  # running in this deployment. It includes information about the nginx and
  # haproxy ports the app uses, as well as the language the app is written
  # in.
  attr_accessor :app_info_map


  # A lock that should be used whenever we modify internal state that can be
  # modified by more than one thread at a time.
  attr_accessor :state_change_lock


  # A Hash that maps the names of Google App Engine apps running in this AppScale
  # deployment to the total number of requests that haproxy has processed.
  attr_accessor :total_req_rate


  # A Hash that maps the names of Google App Engine apps running in this AppScale
  # deployment to the current number of requests that haproxy has queued.
  attr_accessor :current_req_rate


  # A Hash that maps the names of Google App Engine apps running in this AppScale
  # deployment to the last time we sampled the total number of requests that
  # haproxy has processed. When combined with total_req_rate, we can infer the
  # average number of requests per second that come in for each App Engine
  # application.
  attr_accessor :last_sampling_time


  # A Time that corresponds to the last time this machine added or removed nodes
  # in this AppScale deployment. Adding or removing nodes can happen in response
  # to autoscaling requests, or (eventually) to recover from faults.
  attr_accessor :last_scaling_time


  # A Hash that maps reservation IDs generated when uploading App Engine apps
  # via the AppDashboard to the status of the uploaded app (e.g., started
  # uploading, failed because of a bad app.yaml).
  attr_accessor :app_upload_reservations


  # The port that the AppController runs on by default
  SERVER_PORT = 17443


  # The port that SSH connections are hosted over, by default.
  SSH_PORT = 22


  # A boolean that should be used when we are waiting for a specific port
  # to open, and only if that port needs SSL to talk over it.
  USE_SSL = true


  # A boolean that indicates whether or not we should turn the firewall on,
  # and continuously keep it on. Should definitely be on for releases, and
  # on whenever possible.
  FIREWALL_IS_ON = true


  # The location on the local filesystem where AppScale-related configuration
  # files are written to.
  APPSCALE_CONFIG_DIR = "/etc/appscale"


  # The location on the local filesystem where the AppController writes
  # the location of all the nodes which are taskqueue nodes.
  TASKQUEUE_FILE = "#{APPSCALE_CONFIG_DIR}/taskqueue_nodes"


  APPSCALE_HOME = ENV['APPSCALE_HOME']


  # The location on the local filesystem where we save data that should be
  # persisted across AppScale deployments. Currently this is Cassandra data,
  # ZooKeeper data, and Google App Engine apps that users upload.
  PERSISTENT_MOUNT_POINT = "/opt/appscale"


  # The location where we can find the Python 2.7 executable, included because
  # it is not the default version of Python installed on AppScale VMs.
  PYTHON27 = "/usr/bin/python2"


  # The message that we display to the user if they call a SOAP-accessible
  # function with a malformed input (e.g., of the wrong class or format).
  BAD_INPUT_MSG = JSON.dump({'success' => false, 'message' => 'bad input'})


  # The message to display to users if they try to add nodes to a one node
  # deployment, which currently is not supported.
  CANT_SCALE_FROM_ONE_NODE = JSON.dump({
    'success' => false,
    'message' => "can't scale up from a one node deployment"
  })


  # The message that we display to the user if they want to scale up services
  # in an Xen/KVM deployment but don't have enough open nodes to do so.
  NOT_ENOUGH_OPEN_NODES = JSON.dump({'success' => false,
    'message' => 'not enough open nodes'})


  # This is the duty cycle for the main loop(s).
  DUTY_CYCLE = 10


  # How many minutes to print the stats in the logs.
  PRINT_STATS_MINUTES = 30


  # This is the time to wait before aborting after a crash. We use this
  # time to give a chance to the tools to collect the crashlog.
  WAIT_TO_CRASH = 30


  # This is a 'small' sleep that we generally use when waiting for
  # services to be up.
  SMALL_WAIT = 5


  # How often we should attempt to increase the number of AppServers on a
  # given node. It's measured as a multiplier of DUTY_CYCLE.
  SCALEUP_THRESHOLD = 5


  # How often we should attempt to decrease the number of AppServers on a
  # given node. It's measured as a multiplier of DUTY_CYCLE.
  SCALEDOWN_THRESHOLD = 15


  # When spinning new node up or down, we need to use a much longer time
  # to dampen the scaling factor, to give time to the instance to fully
  # boot, and to reap the benefit of an already running instance. This is
  # a multiplication factor we use with the above thresholds.
  SCALE_TIME_MULTIPLIER = 6


  # This is the generic retries to do.
  RETRIES = 5


  # This is more number of retries for methods that take longer.
  MAX_RETRIES = 10


  # The position in the haproxy profiling information where the name of
  # the service (e.g., the frontend or backend) is specified.
  SERVICE_NAME_INDEX = 1


  # The position in the haproxy profiling information where the number of
  # enqueued requests is specified.
  REQ_IN_QUEUE_INDEX = 2


  # The position in the haproxy profiling information where the total number of
  # requests seen for a given app is specified.
  TOTAL_REQUEST_RATE_INDEX = 48


  # Scales up the number of AppServers used to host an application if the
  # request rate rises above this value.
  SCALEUP_REQUEST_RATE_THRESHOLD = 5


  # Scales down the number of AppServers used to host an application if the
  # request rate falls below this value.
  SCALEDOWN_REQUEST_RATE_THRESHOLD = 2


  # The minimum number of requests that have to sit in haproxy's wait queue for
  # an App Engine application before we will scale up the number of AppServers
  # that serve that application.
  SCALEUP_QUEUE_SIZE_THRESHOLD = 5


  # The path to the file where we will store information about AppServer
  # scaling decisions.
  AUTOSCALE_LOG_FILE = "/var/log/appscale/autoscale.log"


  # A Float that determines how much CPU can be used before the autoscaler will
  # stop adding AppServers on a node.
  MAX_CPU_FOR_APPSERVERS = 90.00


  # We won't allow any AppEngine server to have 1 minute average load
  # (normalized on the number of CPUs) to be bigger than this constant.
  MAX_LOAD_AVG = 2.0


  # We need to leave some extra RAM available for the system to operate
  # safely.
  SAFE_MEM = 500

  # A regular expression that can be used to match any character that is not
  # acceptable to use in a hostname:port string, used to filter out unacceptable
  # characters from user input.
  NOT_FQDN_REGEX = /[^\w\d\.:\/_-]/


  # A regular expression that can be used to match any character that is not
  # acceptable to use in a hostname:port string, while also allowing the +
  # character to be used. This is used to filter out unacceptable characters
  # from user input where the plus sign is acceptable.
  NOT_FQDN_OR_PLUS_REGEX = /[^\w\d\.\+:\/_-]/


  # A regular expression that can be used to match any character that is not
  # acceptable to use in a e-mail address, used to filter out unacceptable
  # characters from user input.
  NOT_EMAIL_REGEX = /[^\w\d_@-]/


  # An Integer that determines how many log messages we should send at a time
  # to the AppDashboard, for later viewing.
  LOGS_PER_BATCH = 25


  # An Array of Strings, where each String is an appid that corresponds to an
  # application that cannot be relocated within AppScale, because system
  # services assume that they run at a specific location.
  RESERVED_APPS = [AppDashboard::APP_NAME]


  # A Fixnum that indicates what the first port is that can be used for hosting
  # Google App Engine apps.
  STARTING_APPENGINE_PORT = 20000


  # A String that is returned to callers of get_app_upload_status that provide
  # an invalid reservation ID.
  ID_NOT_FOUND = "Reservation ID not found."


  # This String is used to inform the tools that the AppController is not
  # quite ready to receive requests.
  NOT_UP_YET = "not-up-yet"

  # A String that is returned to callers of set_property that provide an invalid
  # instance variable name to set.
  KEY_NOT_FOUND = "No property exists with the given name."


  # Where to put logs.
  LOG_FILE = "/var/log/appscale/controller-17443.log"


  # Where to put the pid of the controller.
  PID_FILE = "/var/run/appscale-controller.pid"


  # List of parameters allowed in the set_parameter (and in AppScalefile
  # at this time). If a default value is specified, it will be used if the
  # parameter is unspecified.
  PARAMETERS_AND_CLASS = {
    'alter_etc_resolv' => [ TrueClass, nil ],
    'controller_logs_to_dashboard' => [ TrueClass, 'False' ],
    'appengine' => [ Fixnum, '2' ],
    'autoscale' => [ TrueClass, nil ],
    'clear_datastore' => [ TrueClass, 'False' ],
    'client_secrets' => [ String, nil ],
    'disks' => [ String, nil ],
    'ec2_access_key' => [ String, nil ],
    'ec2_secret_key' => [ String, nil ],
    'ec2_url' => [ String, nil ],
    'EC2_ACCESS_KEY' => [ String, nil ],
    'EC2_SECRET_KEY' => [ String, nil ],
    'EC2_URL' => [ String, nil ],
    'flower_password' => [ String, nil ],
    'gce_instance_type' => [ String, nil ],
    'gce_user' => [ String, nil ],
    'group' => [ String, nil ],
    'hostname' => [ String, nil ],
    'keyname' => [ String, nil ],
    'ips' => [ String, nil ],
    'infrastructure' => [ String, nil ],
    'instance_type' => [ String, nil ],
    'machine' => [ String, nil ],
    'max_images' => [ Fixnum, '0' ],
    'max_memory' => [ Fixnum, '400' ],
    'min_images' => [ Fixnum, '1' ],
    'region' => [ String, nil ],
    'replication' => [ Fixnum, '1' ],
    'project' => [ String, nil ],
    'scp' => [ String, nil ],
    'static_ip' => [ String, nil ],
    'table' => [ String, 'cassandra' ],
    'use_spot_instances' => [ TrueClass, nil ],
    'user_commands' => [ String, nil ],
    'verbose' => [ TrueClass, 'False' ],
    'zone' => [ String, nil ]
  }

  # Template used for rsyslog configuration files.
  RSYSLOG_TEMPLATE_LOCATION = "#{APPSCALE_HOME}/lib/templates/rsyslog-app.conf"

  # Instance variables that we need to restore from the head node.
  DEPLOYMENT_STATE = [
    "@app_info_map",
    "@app_names",
    "@apps_loaded",
    "@nodes",
    "@options",
    "@last_decision"
  ]

  # Creates a new Djinn, which holds all the information needed to configure
  # and deploy all the services on this node.
  def initialize()
    # The password, or secret phrase, that is required for callers to access
    # methods exposed via SOAP.
    @@secret = HelperFunctions.get_secret()

    # An Array of Hashes, where each Hash contains a log message and the time
    # it was logged.
    @@logs_buffer = []

    @@log = Logger.new(STDOUT)
    @@log.level = Logger::INFO

    @my_index = nil
    @my_public_ip = nil
    @my_private_ip = nil
    @apps_to_restart = []
    @kill_sig_received = false
    @done_initializing = false
    @done_loading = false
    @state = "AppController just started"
    @num_appengines = 1
    @all_stats = []
    @last_updated = 0
    @state_change_lock = Monitor.new()

    @initialized_apps = {}
    @total_req_rate = {}
    @current_req_rate = {}
    @last_sampling_time = {}
    @last_scaling_time = Time.now.to_i
    @app_upload_reservations = {}

    # This variable is used to keep track of the list of zookeeper servers
    # we have in this deployment.
    @zookeeper_data = []

    # This variable is used to keep track of the list of memcache servers.
    @memcache_contents = ""

    # The following variables are restored from the headnode ie they are
    # part of the common state of the running deployment.
    @app_info_map = {}
    @app_names = []
    @apps_loaded = []
    @nodes = []
    @options = {}
    @last_decision = {}

    # Make sure monit is started.
    MonitInterface.start_monit()
  end

  # A SOAP-exposed method that callers can use to determine if this node
  # has received information from another node and is starting up.
  def is_done_initializing(secret)
    if valid_secret?(secret)
      return @done_initializing
    else
      return BAD_SECRET_MSG
    end
  end


  # A SOAP-exposed method that callers use to determine if this node has
  # finished starting all the roles it should run when it initially starts.
  def is_done_loading(secret)
    if valid_secret?(secret)
      return @done_loading
    else
      return BAD_SECRET_MSG
    end
  end


  # A SOAP-exposed method that callers can use to get information about what
  # roles each node in the AppScale deployment are running.
  def get_role_info(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    all_nodes = []
    @nodes.each { |node|
      all_nodes << node.to_hash()
    }

    return JSON.dump(all_nodes)
  end


  # A SOAP-exposed method that callers can use to get information about what
  # apps are running on this machine, as well as what ports they are bound to,
  # and what ports run nginx and haproxy in front of them.
  #
  # Args:
  #   secret: A String that authenticates callers.
  # Returns:
  #   BAD_SECRET_MSG if the caller could not be authenticated. If the caller
  #   can be authenticated, a JSON-dumped Hash containing information about
  #   applications on this machine is returned.
  def get_app_info_map(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    return JSON.dump(@app_info_map)
  end


  # A SOAP-exposed method that callers can use to tell this AppController that
  # an app hosted in this cloud needs to have its nginx reverse proxy serving
  # HTTP and HTTPS traffic on different ports.
  #
  # Args:
  #   appid: A String that names the application already running in this
  #     deployment that should be relocated.
  #   http_port: A String or Fixnum that names the port that should be used to
  #     serve HTTP traffic for this app.
  #   https_port: A String or Fixnum that names the port that should be used to
  #     serve HTTPS traffic for this app.
  #   secret: A String that authenticates callers.
  # Returns:
  #   "OK" if the relocation occurred successfully, and a String containing the
  #   reason why the relocation failed in all other cases.
  def relocate_app(appid, http_port, https_port, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    # Only the login node runs relocate.
    if not my_node.is_login?
      Djinn.log_warn("Only login nodes runs relocate.")
      return "Error: this is not the login node."
    end

    Djinn.log_debug("@app_info_map is #{@app_info_map.inspect}")
    http_port = Integer(http_port)
    https_port = Integer(https_port)

    # First, only let users relocate apps to ports that the firewall has open
    # for App Engine apps.
    if http_port != 80 and
       (http_port < Nginx::START_PORT or http_port > Nginx::END_PORT)
      return "Error: HTTP port must be 80, or in the range" +
        " #{Nginx::START_PORT}-#{Nginx::END_PORT}."
    end

    if (https_port < Nginx::START_PORT - Nginx::SSL_PORT_OFFSET or https_port >
        Nginx::END_PORT - Nginx::SSL_PORT_OFFSET) and https_port != 443
      return "Error: HTTPS port must be 443, or in the range " +
         "#{Nginx::START_PORT - Nginx::SSL_PORT_OFFSET}-" +
         "#{Nginx::END_PORT - Nginx::SSL_PORT_OFFSET}."
    end

    # We need to check if http_port and https_port are already in use by
    # another application, so we do that with find_lowest_free_port and we
    # fix the range to the single port.
    if find_lowest_free_port(http_port, http_port, appid) < 0
      return "Error: requested http port is already in use."
    end
    if find_lowest_free_port(https_port, https_port, appid) < 0
      return "Error: requested https port is already in use."
    end

    if RESERVED_APPS.include?(appid)
      return "Error: Can't relocate the #{appid} app."
    end

    # Next, rewrite the nginx config file with the new ports
    Djinn.log_info("Regenerating nginx config for relocated app #{appid}")
    APPS_LOCK.synchronize {
      @app_info_map[appid]['nginx'] = http_port
      @app_info_map[appid]['nginx_https'] = https_port
    }
    proxy_port = @app_info_map[appid]['haproxy']
    my_private = my_node.private_ip
    my_public = my_node.public_ip
    login_ip = get_login.private_ip

    static_handlers = HelperFunctions.parse_static_data(appid)
    Nginx.write_fullproxy_app_config(appid, http_port, https_port, my_public,
      my_private, proxy_port, static_handlers, login_ip,
      @app_info_map[appid]['language'])

    Djinn.log_debug("Done writing new nginx config files!")
    Nginx.reload()

    # Same for any cron jobs the user has set up.
    # TODO: We do this on the login node, but the cron jobs are initially
    # set up on the shadow node. In all supported cases, these are the same
    # node, but there may be an issue if they are on different nodes in
    # the future.
    CronHelper.update_cron(my_public, http_port,
      @app_info_map[appid]['language'], appid)

    # Finally, the AppServer takes in the port to send Task Queue tasks to
    # from a file. Update the file and restart the AppServers so they see
    # the new port. Do this in a separate thread to avoid blocking the caller.
    port_file = "#{APPSCALE_CONFIG_DIR}/port-#{appid}.txt"
    HelperFunctions.write_file(port_file, http_port)

    Thread.new {
      # Notify the UAServer about the new ports.
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      success = uac.add_instance(appid, my_public, http_port, https_port)
      if !success
        Djinn.log_warn("Failed to store relocation ports for #{appid} via the uaserver.")
        return
      end

      @nodes.each { |node|
        if node.private_ip != my_node.private_ip
          HelperFunctions.scp_file(port_file, port_file, node.private_ip,
            node.ssh_key)
        end
        next if not node.is_appengine?
        app_manager = AppManagerClient.new(node.private_ip)
        begin
          app_manager.restart_app_instances_for_app(appid,
            @app_info_map[appid]['language'])
        rescue FailedNodeException
          Djinn.log_warn("#{appid} may have not restarted on #{node.private_ip} upon relocate.")
        end
      }
    }

    # Once we've relocated the app, we need to tell the XMPPReceiver about the
    # app's new location.
    MonitInterface.restart("xmpp-#{appid}")

    return "OK"
  end


  # A SOAP-exposed method that tells the AppController to terminate all services
  # in this AppScale deployment.
  #
  # Args:
  #   stop_deployment: A boolean to indicate if the whole deployment
  #                    should be stopped.
  #   secret         : A String used to authenticate callers.
  # Returns:
  #   A String indicating that the termination has started, or the reason why it
  #   failed.
  def kill(stop_deployment, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end
    @kill_sig_received = true

    Djinn.log_info("Received a stop request.")

    if my_node.is_login? and stop_deployment
      Djinn.log_info("Stopping all other nodes.")
      # Let's stop all other nodes.
      threads << Thread.new {
        @nodes.each { |node|
          if node.private_ip != my_node.private_ip
            acc = AppControllerClient.new(ip, @@secret)
            begin
              acc.kill(stop_deployment)
              Djinn.log_info("kill: sent kill command to node at #{ip}.")
            rescue FailedNodeException
              Djinn.log_warn("kill: failed to talk to node at #{ip} while.")
            end
          end
        }
      }
    end

    if @options['alter_etc_resolv'].downcase == "true"
      HelperFunctions.restore_etc_resolv()
    end
    Djinn.log_info("---- Stopping AppController ----")

    return "OK"
  end


  # Validates and sets the instance variables that Djinn needs before it can
  # begin configuring and deploying services on a given node (and if it is the
  # first Djinn, starting up the other Djinns).
  def set_parameters(djinn_locations, database_credentials, app_names, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    if djinn_locations.class != String
      msg = "Error: djinn_locations wasn't a String, but was a " +
        djinn_locations.class.to_s
      Djinn.log_error(msg)
      return msg
    end
    locations = JSON.load(djinn_locations)

    if database_credentials.class != Array
      msg = "Error: database_credentials wasn't an Array, but was a " +
        database_credentials.class.to_s
      Djinn.log_error(msg)
      return msg
    end

    if app_names.class != Array
      msg = "Error: app_names wasn't an Array, but was a " +
        app_names.class.to_s
      Djinn.log_error(msg)
      return msg
    end

    # credentials is an array that we're converting to
    # hash tables, so we need to make sure that every key maps to a value
    # e.g., ['foo', 'bar'] becomes {'foo' => 'bar'}
    # so we need to make sure that the array has an even number of elements
    if database_credentials.length % 2 != 0
      msg = "Error: DB Credentials wasn't of even length: Len = " + \
        "#{database_credentials.length}"
      Djinn.log_error(msg)
      return msg
    end

    possible_credentials = Hash[*database_credentials]
    if !valid_format_for_credentials(possible_credentials)
      return "Error: Credential format wrong"
    end

    keyname = possible_credentials["keyname"]
    @options = possible_credentials
    @app_names = app_names

    nodes = Djinn.convert_location_array_to_class(locations, keyname)
    converted_nodes = convert_fqdns_to_ips(nodes)
    @state_change_lock.synchronize {
      @nodes = converted_nodes
    }
    @options = sanitize_credentials()

    # Check that we got good parameters: we removed the unkown ones for
    # backward compatibilty.
    options_to_delete = []
    @options.each { |key, val|
      # Is the parameter known?
      if PARAMETERS_AND_CLASS.has_key?(key) == false
        begin
          msg = "Removing unknown parameter '" + key.to_s + "'."
        rescue
          msg = "Removing unknown parameter."
        end
        Djinn.log_warn(msg)
        options_to_delete.push(key)
        next
      end

      # Check that the value that came in is a String or as final class of
      # the parameter. There is no boolean, so TrueClass and FalseClass
      # needs to be check both. If not, remove the parameter since we
      # won't be able to translate it.
      if not (val.class == String or val.class == PARAMETERS_AND_CLASS[key][0] or
         (PARAMETERS_AND_CLASS[key][0] == TrueClass and val.class == FalseClass))
        begin
          msg = "Removing parameter '" + key + "' with unknown value '" +\
            val.to_s + "'."
        rescue
          msg = "Removing parameter '" + key + "' with unknown value."
        end
        Djinn.log_warn(msg)
        options_to_delete.push(key)
        next
      end

      msg = "Converting '" + key + "' with value '" + val + "'."
      Djinn.log_info(msg)

      # Let's check if we can convert them now to the proper class.
      if PARAMETERS_AND_CLASS[key][0] == Fixnum
        begin
          test_value = Integer(val)
        rescue
          msg = "Warning: parameter '" + key + "' is not an integer (" +\
            val.to_s + "). Removing it."
          Djinn.log_warn(msg)
          options_to_delete.push(key)
          next
        end
      end

      # Booleans and Integer (basically non-String) seem to create issues
      # at the SOAP level (possibly because they are in a structure) with
      # message similar to "failed to serialize detail object". We convert
      # them here to String.
      if PARAMETERS_AND_CLASS[key][0] == TrueClass or
        PARAMETERS_AND_CLASS[key][0] == Fixnum
        begin
          @options[key] = val.to_s
        rescue
          msg = "Warning: cannot convert '" + key + "' to string. Removing it."
          Djinn.log_warn(msg)
          options_to_delete.push(key)
        end
        next
      end
    }
    options_to_delete.each { |key|
      @options.delete(key)
    }

    # Now let's make sure the parameters that needs to have values are
    # indeed defines, otherwise set the defaults.
    PARAMETERS_AND_CLASS.each { |key, key_type, val|
      if @options[key]
        # The parameter 'key' is defined, no need to do anything.
        next
      end
      if PARAMETERS_AND_CLASS[key][1]
         # The parameter has a default, and it's not defined. Adding
         # default value.
         @options[key] = PARAMETERS_AND_CLASS[key][1]
      end
    }

    find_me_in_locations()
    if @my_index.nil?
      return "Error: Couldn't find me in the node map"
    end

    ENV['EC2_URL'] = @options['ec2_url']

    if @options['ec2_access_key'].nil?
      @options['ec2_access_key'] = @options['EC2_ACCESS_KEY']
      @options['ec2_secret_key'] = @options['EC2_SECRET_KEY']
      @options['ec2_url'] = @options['EC2_URL']
    end

    if @options['alter_etc_resolv'].downcase == "true"
      HelperFunctions.alter_etc_resolv()
    end

    @@log.level = Logger::DEBUG if @options['verbose'].downcase == "true"

    begin
      @options['zone'] = JSON.load(@options['zone'])
    rescue JSON::ParserError
      Djinn.log_info("Fail to parse 'zone': ignoring it.")
    end

    Djinn.log_run("mkdir -p #{PERSISTENT_MOUNT_POINT}/apps")

    Djinn.log_debug("set_parameters: set @options to #{@options}.")
    Djinn.log_debug("set_parameters: set @nodes to #{@nodes}.")

    return "OK"
  end


  # Gets the status of the current node in the AppScale deployment
  #
  # Args:
  #   secret: The shared key for authentication
  # Returns:
  #   A string with the current node's status
  #
  def status(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    stats = get_stats(secret)

    stats_str = <<-STATUS
    Currently using #{stats['cpu']} Percent CPU and #{stats['memory']} Percent Memory
    Hard disk is #{stats['disk']} Percent full
    Is currently: #{stats['roles'].join(', ')}
    Database is at #{stats['db_location']}
    Is in cloud: #{stats['cloud']}
    Current State: #{stats['state']}
    STATUS

    if my_node.is_login?
      app_names = []
      stats['apps'].each { |k, v|
        app_names << k
      }

      stats_str << "    Hosting the following apps: #{app_names.join(', ')}\n"

      stats['apps'].each { |app_name, is_loaded|
        next if !is_loaded
        next if app_name == "none"
        stats_str << "    Information for application: #{app_name}\n"
        stats_str << "        Language            : "
        if !@app_info_map[app_name]['language'].nil?
          stats_str << "#{@app_info_map[app_name]['language']}\n"
        else
          stats_str << "Unknown\n"
        end
        stats_str << "        Number of AppServers: "
        if !@app_info_map[app_name]['appengine'].nil?
          running = 0
          pending = 0
          @app_info_map[app_name]['appengine'].each{ |location|
             host, port = location.split(":")
             if Integer(port) > 0
               running += 1
             else
               pending += 1
             end
          }
          stats_str << "#{running} running"
          if pending > 0
            stats_str << ", #{pending} pending"
          end
          stats_str << "\n"
        else
          stats_str << "Unknown\n"
        end
        stats_str << "        HTTP port           : "
        if !@app_info_map[app_name]['nginx'].nil?
          stats_str << "#{@app_info_map[app_name]['nginx']}\n"
        else
          stats_str << "Unknown\n"
        end
        stats_str << "        HTTPS port          : "
        if !@app_info_map[app_name]['nginx_https'].nil?
          stats_str << "#{@app_info_map[app_name]['nginx_https']}\n"
        else
          stats_str << "Unknown\n"
        end
      }
    end

    return stats_str
  end

  # Upload a Google App Engine application into this AppScale deployment.
  #
  # Args:
  #   archived_file: A String, with the path to the compressed file containing
  #     the app.
  #   file_suffix: A String indicating what suffix the file should have.
  #   email: A String with the email address of the user that will own this app.
  #   secret: A String with the shared key for authentication.
  # Returns:
  #   A JSON-dumped Hash with fields indicating if the upload process began
  #   successfully, and a reservation ID that can be used with
  #   get_app_upload_status to see if the app has successfully uploaded or not.
  def upload_app(archived_file, file_suffix, email, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    reservation_id = HelperFunctions.get_random_alphanumeric()
    @app_upload_reservations[reservation_id] = {'status' => 'starting'}

    Djinn.log_debug("Received a request to upload app at #{archived_file}, with suffix #{file_suffix}, with admin user #{email}.")

    Thread.new {
      if !archived_file.match(/#{file_suffix}$/)
        archived_file_old = archived_file
        archived_file = "#{archived_file_old}.#{file_suffix}"
        Djinn.log_debug("Renaming #{archived_file_old} to #{archived_file}")
        File.rename(archived_file_old, archived_file)
      end

      Djinn.log_debug("Uploading file at location #{archived_file}")
      keyname = @options['keyname']
      command = "appscale-upload-app --file '#{archived_file}' " +
        "--email #{email} --keyname #{keyname} 2>&1"
      output = Djinn.log_run("#{command}")
      if output.include?("Your app can be reached at the following URL")
        result = "true"
      else
        result = output
      end

      @app_upload_reservations[reservation_id]['status'] = result
    }

    return JSON.dump({
      'reservation_id' => reservation_id,
      'status' => 'starting'
    })
  end

  # Checks the status of the App Engine app uploading with the given reservation
  # ID.
  #
  # Args:
  #   reservation_id: A String that corresponds to the reservation ID given when
  #     the app upload process began.
  #   secret: A String with the shared key for authentication.
  # Returns:
  #   A String that indicates what the state is of the uploaded application. If
  #   the given reservation ID was not found, ID_NOT_FOUND is returned. If the
  #   caller attempts to authenticate with an invalid secret, BAD_SECRET_MSG is
  #   returned.
  def get_app_upload_status(reservation_id, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    if @app_upload_reservations[reservation_id]['status']
      return @app_upload_reservations[reservation_id]['status']
    else
      return ID_NOT_FOUND
    end
  end

  # Gets the statistics of all the nodes in the AppScale deployment.
  #
  # Args:
  #   secret: A string with the shared key for authentication.
  # Returns:
  #   A JSON string with the statistics of the nodes.
  def get_stats_json(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    return JSON.dump(@all_stats)
  end


  # Updates our locally cached information about the CPU, memory, and disk
  # usage of each machine in this AppScale deployment.
  def update_node_info_cache()
    new_stats = []

    Thread.new {
      @nodes.each { |node|
        ip = node.private_ip
        if ip == my_node.private_ip
          new_stats << get_stats(@@secret)
        else
          acc = AppControllerClient.new(ip, @@secret)
          begin
            new_stats << acc.get_stats()
          rescue FailedNodeException
            Djinn.log_warn("Failed to get status update from node at #{ip}, so " +
              "not adding it to our cached info.")
          end
        end
      }
      @all_stats = new_stats
    }
  end


  # Gets the database information of the AppScale deployment.
  #
  # Args:
  #   secret: A string with the shared key for authentication.
  # Returns:
  #   A JSON string with the database information.
  def get_database_information(secret)
    tree = { :table => @options['table'], :replication => @options['replication'],
      :keyname => @options['keyname'] }
    return JSON.dump(tree)
  end

  # Gets the statistics of only this node.
  #
  # Args:
  #   secret: A string with the shared key for authentication.
  # Returns:
  #   A Hash with the statistics of this node.
  def get_stats(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    usage = HelperFunctions.get_usage()
    mem = sprintf("%3.2f", usage['mem'])
    usagecpu = sprintf("%3.2f", usage['cpu'])

    jobs = my_node.jobs or ["none"]
    # don't use an actual % below, or it will cause a string format exception
    stats = {
      'ip' => my_node.public_ip,
      'private_ip' => my_node.private_ip,
      'cpu' => usagecpu,
      'num_cpu' => usage['num_cpu'],
      'load' => usage['load'],
      'memory' => mem,
      'free_memory' => Integer(usage['free_mem']),
      'disk' => usage['disk'],
      'roles' => jobs,
      'cloud' => my_node.cloud,
      'state' => @state
    }

    # As of 2.5.0, db_locations is used by the tools to understand when
    # the AppController is setup and ready to go: we make sure here to
    # follow that rule.
    if @done_initializing
      stats['db_location'] = get_db_master.public_ip
    else
      stats['db_location'] = NOT_UP_YET
    end

    stats['apps'] = {}
    @app_names.each { |name|
      stats['apps'][name] = @apps_loaded.include?(name)
    }
    return stats
  end


  # Runs the Groomer service that the Datastore provides, which cleans up
  # deleted entries and generates statistics about the entities stored for each
  # application.
  #
  # Args:
  #   secret: A String with the shared key for authentication.
  # Returns:
  #   'OK' if the groomer was invoked, and BAD_SECRET_MSG if the user failed to
  #   authenticate correctly.
  def run_groomer(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    Thread.new {
      run_groomer_command = "#{PYTHON27} #{APPSCALE_HOME}/AppDB/groomer.py"
      if my_node.is_db_master?
        Djinn.log_run(run_groomer_command)
      else
        db_master = get_db_master()
        HelperFunctions.run_remote_command(db_master.private_ip,
          run_groomer_command, db_master.ssh_key, NO_OUTPUT)
      end
    }

    return 'OK'
  end


  # Queries the AppController for a list of instance variables whose names match
  # the given regular expression, as well as the values associated with each
  # match.
  #
  # Args:
  #   property_regex: A String that will be used as the regular expression,
  #     determining which instance variables should be returned.
  #   secret: A String with the shared key for authentication.
  #
  # Returns:
  #   A JSON-dumped Hash mapping each instance variable matching the given regex
  #   to the value it is bound to.
  def get_property(property_regex, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    properties = {}
    instance_variables.each { |name|
      name_without_at_sign = name[1..name.length-1]
      begin
        if name_without_at_sign =~ /\A#{property_regex}\Z/
          value = instance_variable_get(name)
          properties[name_without_at_sign] = value
        end
      rescue RegexpError
      end
    }

    Djinn.log_debug("Caller asked for instance variables matching regex " +
      "#{property_regex}, returning response #{properties.inspect}")
    return JSON.dump(properties)
  end


  # Sets the named instance variable to the given value.
  #
  # Args:
  #   property_name: A String naming the instance variable that should be set.
  #   property_value: A String or Fixnum that provides the value for the given
  #     property name.
  #   secret: A String with the shared key for authentication.
  #
  # Returns:
  #   A String containing:
  #     - 'OK' if the value was successfully set.
  #     - KEY_NOT_FOUND if there is no instance variable with the given name.
  #     - BAD_SECRET_MSG if the caller could not be authenticated.
  def set_property(property_name, property_value, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    Djinn.log_info("Attempting to set @#{property_name} to #{property_value}")

    name_with_at_sign = "@#{property_name}"
    begin
      instance_variable_set(name_with_at_sign, property_value)
    rescue NameError
      Djinn.log_info("Failed to set @#{property_name}")
      return KEY_NOT_FOUND
    end

    Djinn.log_info("Successfully set @#{property_name} to #{property_value}")
    return 'OK'
  end

  # Checks ZooKeeper to see if the deployment ID exists.
  # Returns:
  #   A boolean indicating whether the deployment ID has been set or not.
  def deployment_id_exists(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    return ZKInterface.exists?(DEPLOYMENT_ID_PATH)
  end

  # Retrieves the deployment ID from ZooKeeper.
  # Returns:
  #   A string that contains the deployment ID.
  def get_deployment_id(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      return ZKInterface.get(DEPLOYMENT_ID_PATH)
    rescue FailedZooKeeperOperationException => e
      Djinn.log_warn("(get_deployment_id) failed talking to zookeeper " +
        "with #{e.message}.")
      return
    end
  end

  # Sets deployment ID in ZooKeeper.
  # Args:
  #   id: A string that contains the deployment ID.
  def set_deployment_id(secret, id)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      ZKInterface.set(DEPLOYMENT_ID_PATH, id, false)
    rescue FailedZooKeeperOperationException => e
      Djinn.log_warn("(set_deployment_id) failed talking to zookeeper " +
        "with #{e.message}.")
    end
    return
  end

  # Enables or disables datastore writes on this node.
  # Args:
  #   read_only: A string that indicates whether to turn read-only mode on or
  #     off.
  def set_node_read_only(read_only, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end
    return INVALID_REQUEST unless %w(true false).include?(read_only)
    read_only = read_only == 'true'

    DatastoreServer.set_read_only_mode(read_only)
    if read_only
      GroomerService.stop()
    else
      GroomerService.start()
    end

    return 'OK'
  end

  # Enables or disables datastore writes on this deployment.
  # Args:
  #   read_only: A string that indicates whether to turn read-only mode on or
  #     off.
  def set_read_only(read_only, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end
    return INVALID_REQUEST unless %w(true false).include?(read_only)

    @nodes.each { | node |
      if node.is_db_master? or node.is_db_slave?
        acc = AppControllerClient.new(node.private_ip, @@secret)
        response = acc.set_node_read_only(read_only)
        return response unless response == 'OK'
      end
    }

    return 'OK'
  end

  # Queries the UserAppServer to see if the named application exists,
  # and if it is listening to any port.
  #
  # Args:
  #   appname: The name of the app that we should check for existence.
  # Returns:
  #   A boolean indicating whether or not the user application exists.
  def does_app_exist(appname, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.does_app_exist?(appname)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer to check if the  " +
        "application #{appname} exists")
    end
  end

  # Resets a user's password.
  #
  # Args:
  #   username: The email address for the user whose password will be changed.
  #   password: The SHA1-hashed password that will be set as the user's password.
  def reset_password(username, password, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.change_password(username, password)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer while resetting " +
        "the user's password.")
    end
  end

  # Queries the UserAppServer to see if the given user exists.
  #
  # Args:
  #   username: The email address registered as username for the user's application.
  def does_user_exist(username, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.does_user_exist?(username)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer to check if the " +
        "the user #{username} exists.")
    end
  end

  # Creates a new user account, with the given username and hashed password.
  #
  # Args:
  #   username: An email address that should be set as the new username.
  #   password: A sha1-hashed password that is bound to the given username.
  #   account_type: A str that indicates if this account can be logged into
  #     by XMPP users.
  def create_user(username, password, account_type, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.commit_new_user(username, password, account_type)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer while commiting " +
        "the user #{username}.")
    end
  end

  # Grants the given user the ability to perform any administrative action.
  #
  # Args:
  #   username: The e-mail address that should be given administrative authorizations.
  def set_admin_role(username, is_cloud_admin, capabilities, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.set_admin_role(username, is_cloud_admin, capabilities)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer while setting admin role " +
        "for the user #{username}.")
    end
  end

  # Retrieve application metadata from the UAServer.
  #
  #  Args:
  #    app_id: A string containing the application ID.
  #  Returns:
  #    A JSON-encoded string containing the application metadata.
  def get_app_data(app_id, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.get_app_data(app_id)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer while getting the app " +
        "admin for the application #{app_id}.")
    end
  end

  # Tells the UserAppServer to reserve the given app_id for
  # a particular user.
  #
  # Args:
  #   username: A str representing the app administrator's e-mail address.
  #   app_id: A str representing the application ID to reserve.
  #   app_language: The runtime (Python 2.5/2.7, Java, or Go) that the app
  #     runs over.
  def reserve_app_id(username, app_id, app_language, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    begin
      uac = UserAppClient.new(my_node.private_ip, @@secret)
      return uac.commit_new_app_name(username, app_id, app_language)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer while reserving app id " +
        "for the application #{app_id}.")
    end
  end

  # Removes an application and stops all AppServers hosting this application.
  #
  # Args:
  #   app_name: The application to stop
  #   secret: Shared key for authentication
  #
  def stop_app(app_name, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    app_name.gsub!(/[^\w\d\-]/, "")
    Djinn.log_info("Shutting down app named [#{app_name}]")
    result = ""
    Djinn.log_run("rm -rf #{HelperFunctions.get_app_path(app_name)}")
    CronHelper.clear_app_crontab(app_name)

    # app shutdown process can take more than 30 seconds
    # so run it in a new thread to avoid 'execution expired'
    # error messages and have the tools poll it
    Thread.new {
      # The login node has extra stuff to do: remove the xmpp listener and
      # inform the other nodes to stop the application, and remove the
      # application from the metadata (soap_server).
      if my_node.is_login?
        begin
          uac = UserAppClient.new(my_node.private_ip, @@secret)
          if not uac.does_app_exist?(app_name)
            Djinn.log_info("(stop_app) #{app_name} does not exist.")
          else
            result = uac.delete_app(app_name)
            Djinn.log_debug("(stop_app) delete_app returned: #{result}.")
          end
        rescue FailedNodeException
          Djinn.log_warn("(stop_app) delete_app: failed to talk " +
            "to the UserAppServer.")
        end
        @nodes.each { |node|
          next if node.private_ip == my_node.private_ip
          if node.is_appengine?
            ip = node.private_ip
            acc = AppControllerClient.new(ip, @@secret)
            begin
              result = acc.stop_app(app_name)
              Djinn.log_debug("Removing application #{app_name} from #{ip} " +
                "returned #{result}")
            rescue FailedNodeException
              Djinn.log_warn("Could not remove application #{app_name} from " +
                "#{ip} - moving on to other nodes.")
            end
          end
        }
        pid_files = HelperFunctions.shell("ls #{APPSCALE_CONFIG_DIR}/xmpp-#{app_name}.pid").split
        unless pid_files.nil? # not an error here - XMPP is optional
          pid_files.each { |pid_file|
            pid = HelperFunctions.read_file(pid_file)
            Djinn.log_run("kill -9 #{pid}")
          }
        end
        stop_xmpp_for_app(app_name)
      end

      Djinn.log_debug("(stop_app) Maybe stopping taskqueue worker")
      maybe_stop_taskqueue_worker(app_name)
      Djinn.log_debug("(stop_app) Done maybe stopping taskqueue worker")

      APPS_LOCK.synchronize {
        if my_node.is_login?
          Nginx.remove_app(app_name)
          HAProxy.remove_app(app_name)
        end

        if my_node.is_appengine?
          Djinn.log_debug("(stop_app) Calling AppManager for app #{app_name}")
          app_manager = AppManagerClient.new(my_node.private_ip)
          begin
            if app_manager.stop_app(app_name)
              Djinn.log_info("(stop_app) AppManager shut down app #{app_name}")
            else
              Djinn.log_error("(stop_app) unable to stop app #{app_name}")
            end
          rescue FailedNodeException
            Djinn.log_warn("(stop_app) #{app_name} may have not been stopped")
          end

          begin
            ZKInterface.remove_app_entry(app_name, my_node.public_ip)
          rescue FailedZooKeeperOperationException => e
            Djinn.log_warn("(stop_app) got exception talking to " +
              "zookeeper: #{e.message}.")
          end
        end

        # If this node has any information about AppServers for this app,
        # clear that information out.
        if !@app_info_map[app_name].nil?
          @app_info_map.delete(app_name)
        end

        @apps_loaded = @apps_loaded - [app_name]
        @app_names = @app_names - [app_name]

        if @apps_loaded.empty?
          @apps_loaded << "none"
        end

        if @app_names.empty?
          @app_names << "none"
        end
      } # end of lock
    } # end of thread

    return "true"
  end

  # Stop taskqueue worker on this local machine.
  #
  # Args:
  #   app: The application ID.
  def maybe_stop_taskqueue_worker(app)
    if my_node.is_taskqueue_master? or my_node.is_taskqueue_slave?
      Djinn.log_info("Stopping TaskQueue workers for app #{app}")
      tqc = TaskQueueClient.new()
      begin
        result = tqc.stop_worker(app)
        Djinn.log_info("Stopped TaskQueue workers for app #{app}: #{result}")
      rescue FailedNodeException
        Djinn.log_warn("Failed to stop TaskQueue workers for app #{app}")
      end
    end
  end

  # Start taskqueue worker on this local machine.
  #
  # Args:
  #   app: The application ID.
  def maybe_start_taskqueue_worker(app)
    if my_node.is_taskqueue_master? or my_node.is_taskqueue_slave?
      tqc = TaskQueueClient.new()
      begin
        result = tqc.start_worker(app)
        Djinn.log_info("Starting TaskQueue worker for app #{app}: #{result}")
      rescue FailedNodeException
        Djinn.log_warn("Failed to start TaskQueue workers for app #{app}")
      end
    end
  end

  # Reload the queue information of an app and reload the queues if needed.
  #
  # Args:
  #   app: The application ID.
  def maybe_reload_taskqueue_worker(app)
    if my_node.is_taskqueue_master? or my_node.is_taskqueue_slave?
      tqc = TaskQueueClient.new()
      begin
        result = tqc.reload_worker(app)
        Djinn.log_info("Checking TaskQueue worker for app #{app}: #{result}")
      rescue FailedNodeException
        Djinn.log_warn("Failed to reload TaskQueue workers for app #{app}")
      end
    end
  end

  def update(app_names, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    # Few sanity checks before acting.
    if not my_node.is_login?
      Djinn.log_warn("I'm not a login node, but received an update request.")
      return "Error: server is not a login node."
    end
    if app_names.class != Array
      return "app_names was not an Array but was a #{app_names.class}."
    end

    Djinn.log_info("Received request to update these apps: #{app_names.join(', ')}.")

    # Begin by marking the apps that should be running.
    current_apps_uploaded = @apps_loaded
    Djinn.log_debug("Running apps: #{app_names.join(', ')}.")

    # Get a list of the apps we need to restart.
    apps_to_restart = current_apps_uploaded & app_names
    Djinn.log_debug("Apps to restart are #{apps_to_restart}")

    # Next, check if the language of the application is correct.
    app_names.each{ |app|
      if check_app_language(app) == INVALID_REQUEST
        apps_to_restart.delete(app)
        result = stop_app(app, @@secret)
        Djinn.log_error("Disabling app #{app} because of invalid language.")
      end
    }

    # Next, restart any apps that have new code uploaded.
    if !apps_to_restart.empty?
      apps_to_restart.each { |appid|
        location = "#{PERSISTENT_MOUNT_POINT}/apps/#{appid}.tar.gz"
        begin
          ZKInterface.clear_app_hosters(appid)
          ZKInterface.add_app_entry(appid, my_node.public_ip, location)
        rescue FailedZooKeeperOperationException => e
          Djinn.log_warn("(update) couldn't talk with zookeeper while " +
            "working on app #{appid} with #{e.message}.")
        end
      }

      @nodes.each_index { |index|
        result = ""
        ip = @nodes[index].private_ip
        if my_node.private_ip == ip
          result = set_apps_to_restart(apps_to_restart, @@secret)
        else
          acc = AppControllerClient.new(ip, @@secret)
          begin
            result = acc.set_apps_to_restart(apps_to_restart)
          rescue FailedNodeException
            Djinn.log_warn("Couldn't tell #{ip} to restart Google App Engine " +
              "apps - skipping for now.")
          end
        end
        Djinn.log_debug("Set apps to restart at #{ip} returned #{result} as class #{result.class}")
      }

      if my_node.is_login?
        regenerate_nginx_config_files()
      end
    end

    APPS_LOCK.synchronize {
      # Since we have at least one application running, we don't need to
      # display anymore 'none' as the list of running applications.
      @app_names |= app_names
      @app_names = @app_names - ["none"]
    }
    Djinn.log_debug("Done updating apps!")

    return "OK"
  end

  # Adds the list of apps that should be restarted to this node's list of apps
  # that should be restarted.
  #
  # Args:
  #   apps_to_restart: An Array of Strings, where each String is an appid
  #     corresponding to an application that should be restarted.
  #   secret: The String that authenticates the caller.
  # Returns:
  #   A String indicating that the SOAP call succeeded, or the reason why it
  #   did not.
  def set_apps_to_restart(apps_to_restart, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    APPS_LOCK.synchronize {
      @apps_to_restart += apps_to_restart
      @apps_to_restart.uniq!
    }
    Djinn.log_debug("Apps to restart is now [#{@apps_to_restart.join(', ')}]")

    return "OK"
  end

  def get_all_public_ips(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    public_ips = []
    @nodes.each { |node|
      public_ips << node.public_ip
    }
    return JSON.dump(public_ips)
  end

  def job_start(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    Djinn.log_info("==== Starting AppController (pid: #{Process.pid}) ====")

    # This pid is used to control this deployment using the init script.
    HelperFunctions.write_file(PID_FILE, "#{Process.pid}")

    # If we have the ZK_LOCATIONS_FILE, the deployment has already been
    # configured and started. We need to check if we are a zookeeper host
    # and start it if needed.
    if File.exists?(ZK_LOCATIONS_FILE)
      # We need to check our saved IPs with the list of zookeeper nodes
      # (IPs can change in cloud environments).
      begin
        my_ip = HelperFunctions.read_file("#{APPSCALE_CONFIG_DIR}/my_private_ip")
      rescue Errno::ENOENT
        @state = "Cannot find my old private IP address."
        HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
      end

      # Restore the initial list of zookeeper nodes.
      zookeeper_data = HelperFunctions.read_json_file(ZK_LOCATIONS_FILE)
      @zookeeper_data = zookeeper_data['locations']
      if @zookeeper_data.include?(my_ip) and !is_zookeeper_running?
        # We are a zookeeper host and we need to start it.
        Djinn.log_info("Starting zookeeper.")
        begin
          start_zookeeper(false)
        rescue FailedZooKeeperOperationException
          @state = "Couldn't start Zookeeper."
          HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
        end
      end
      pick_zookeeper(@zookeeper_data)
    end

    start_infrastructure_manager()

    # We need to wait for the 'state', that is the deployment layouts and
    # the options for this deployment. It's either a save state from a
    # previous start, or it comes from the tools. If the tools communicate
    # the deployment's data, then we are the headnode.
    if !restore_appcontroller_state()
      erase_old_data()
      wait_for_data()
    end
    parse_options()

    # We reset the kill signal received since we are starting now.
    @kill_sig_received = false

    # From here on we have the basic local state that allows to operate.
    # In particular we know our roles, and the deployment layout. Let's
    # start attaching any permanent disk we may have associated with us.
    mount_persistent_storage

    # If we are the headnode, we may need to start/setup all other nodes.
    # Better do it early on, since it may take some time for the other
    # nodes to start up.
    if my_node.is_shadow?
      Djinn.log_info("Spawning/setting up other nodes.")
      spawn_and_setup_appengine
    end

    # Initialize the current server and starts all the API and essential
    # services. The functions are idempotent ie won't restart already
    # running services and can be ran multiple time with no side effect.
    initialize_server()
    start_api_services()

    # Now that we are done loading, we can set the monit job to check the
    # AppController. At this point we are resilient to failure (ie the AC
    # will restart if needed).
    set_appcontroller_monit()
    @done_loading = true

    write_zookeeper_locations()
    pick_zookeeper(@zookeeper_data)
    write_our_node_info()
    wait_for_nodes_to_finish_loading(@nodes)

    # This variable is used to keep track of the last time we printed some
    # statistics to the log.
    last_print = Time.now.to_i

    while !@kill_sig_received do
      write_database_info()
      update_firewall()
      write_memcache_locations()
      write_zookeeper_locations()
      @state = "Looking up a zookeeper server"
      pick_zookeeper(@zookeeper_data)

      # Reload state from head node.
      if my_node.is_login?
        flush_log_buffer()
        send_instance_info_to_dashboard()
        update_node_info_cache()
      else
        # Every other node syncs its state with the login's node state.
        if !restore_appcontroller_state()
          Djinn.log_warn("Cannot talk to zookeeper: in isolated mode.")
          next
        end
      end

      @state = "Done starting up AppScale, now in heartbeat mode"

      # Only the shadow backup the deployment state to zookeeper.
      backup_appcontroller_state() if my_node.is_shadow?

      # The following is the core of the duty cycle: start new apps,
      # restart apps, terminate non-responsive appserver, and autoscale.
      check_running_apps()
      restart_appengine()
      if my_node.is_login?
        scale_appservers_within_nodes()
        scale_appservers_across_nodes()
      end

      # Print stats in the log recurrently; works as a heartbeat mechanism.
      if last_print < (Time.now.to_i - 60 * PRINT_STATS_MINUTES)
        stats = JSON.parse(get_all_stats(secret))

        Djinn.log_info("--- Node at #{stats['public_ip']} has " +
          "#{stats['memory']['available']/(1024*1024)}MB memory available " +
          "and knows about these apps #{stats['apps']}.")
        last_print = Time.now.to_i
      end

      Kernel.sleep(DUTY_CYCLE)
    end
  end


  # Starts the InfrastructureManager service on this machine, which exposes
  # a SOAP interface by which we can dynamically add and remove nodes in this
  # AppScale deployment.
  def start_infrastructure_manager()
    iaas_script = "#{APPSCALE_HOME}/InfrastructureManager/infrastructure_manager_service.py"
    start_cmd = "#{PYTHON27} #{iaas_script}"
    stop_cmd = "#{PYTHON27} #{APPSCALE_HOME}/scripts/stop_service.py " +
          "#{iaas_script} #{PYTHON27}"
    port = [InfrastructureManagerClient::SERVER_PORT]
    env = {
      'APPSCALE_HOME' => APPSCALE_HOME,
      'EC2_HOME' => ENV['EC2_HOME'],
      'JAVA_HOME' => ENV['JAVA_HOME']
    }

    MonitInterface.start(:iaas_manager, start_cmd, stop_cmd, port, env)
    Djinn.log_info("Started InfrastructureManager successfully!")
  end


  def stop_infrastructure_manager
    Djinn.log_info("Stopping InfrastructureManager")
    MonitInterface.stop(:iaas_manager)
  end


  def get_online_users_list(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    online_users = []

    login_node = get_login()
    ip = login_node.public_ip
    key = login_node.ssh_key
    raw_list = `ssh -i #{key} -o StrictHostkeyChecking=no root@#{ip} 'ejabberdctl connected-users'`
    raw_list.split("\n").each { |userdata|
      online_users << userdata.split("/")[0]
    }

    return online_users
  end

  def done_uploading(appname, location, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    if File.exists?(location)
      begin
        ZKInterface.add_app_entry(appname, my_node.public_ip, location)
        result = "Found #{appname} in zookeeper."
      rescue FailedZooKeeperOperationException => e
        Djinn.log_warn("(done_uploading) couldn't talk to zookeeper " +
          "with #{e.message}.")
        result = "Unknown status for #{appname}: please retry."
      end
    else
      result = "The #{appname} app was not found at #{location}."
    end

    Djinn.log_debug(result)
    return result
  end

  def is_app_running(appname, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    hosters = ZKInterface.get_app_hosters(appname, @options['keyname'])
    hosters_w_appengine = []
    hosters.each { |node|
      hosters_w_appengine << node if node.is_appengine?
    }

    app_running = !hosters_w_appengine.empty?
    Djinn.log_debug("Is app #{appname} running? #{app_running}")
    return app_running
  end


  def add_role(new_role, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    # new roles may run indefinitely in the background, so don't block
    # on them - just fire and forget
    Thread.new {
      start_roles = new_role.split(":")
      start_roles.each { |role|
        # only start roles that we aren't already running
        # e.g., don't start_appengine if we already are, as this
        # will create two threads loading apps
        if my_node.jobs.include?(role)
          Djinn.log_info("Already running role #{role}, not invoking again")
        else
          Djinn.log_info("Adding and starting role #{role}")
          my_node.add_roles(role)
          send("start_#{role}".to_sym)
        end
      }
    }

    return "OK"
  end

  def remove_role(old_role, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    my_node.remove_roles(old_role)
    stop_roles = old_role.split(":")
    stop_roles.each { |role|
      Djinn.log_info("Removing and stopping role #{role}")
      send("stop_#{role}".to_sym)
    }
    return "OK"
  end


  # This SOAP-exposed method dynamically scales up a currently running
  # AppScale deployment. For virtualized clusters, this assumes the
  # user has given us a list of IP addresses where AppScale has been
  # installed to, and for cloud deployments, we assume that the user
  # wants to use the same credentials as for their current deployment.
  # Args:
  #   ips_hash: A Hash that maps roles (e.g., appengine, database) to the
  #     IP address (in virtualized deployments) or unique identifier (in
  #     cloud deployments) that should run that role.
  #   secret: A String password that is used to authenticate the request
  #     to add nodes to the deployment.
  # Returns:
  #   BAD_SECRET_MSG: If the secret given does not match the secret for
  #     this AppScale deployment.
  #   BAD_INPUT_MSG: If ips_hash was not a Hash.
  #   Otherwise, returns a Hash that maps IP addresses to the roles that
  #     will be hosted on them (the inverse of ips_hash).
  def start_roles_on_nodes(ips_hash, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    ips_hash = JSON.load(ips_hash)
    if ips_hash.class != Hash
      Djinn.log_warn("Was expecting ips_hash to be a Hash, not " +
        "a #{ips_hash.class}")
      return BAD_INPUT_MSG
    end

    Djinn.log_info("Received a request to start additional roles on " +
      "new machines, with the following placement strategy: " +
      "#{ips_hash.inspect}")

    # ips_hash maps roles to IPs, but the internal format here maps
    # IPs to roles, so convert to the right format
    ips_to_roles = {}
    ips_hash.each { |role, ip_or_ips|
      if ip_or_ips.class == String
        ips = [ip_or_ips]  # just one IP
      else
        ips = ip_or_ips  # a list of IPs
      end

      ips.each { |ip|
        if ips_to_roles[ip].nil?
          ips_to_roles[ip] = []
        end
        ips_to_roles[ip] << role
      }
    }

    Thread.new {
      if is_cloud?
        start_new_roles_on_nodes_in_cloud(ips_to_roles)
      else
        start_new_roles_on_nodes_in_xen(ips_to_roles)
      end
    }

    return ips_to_roles
  end


  # This method acquires virtual machines from a cloud IaaS and adds them
  # to the currently running AppScale deployment. The new machines are then
  # assigned the roles given to us by the caller.
  # Args:
  #   ips_to_roles: A Hash that maps machines to the roles that should be
  #     started on them. As we have not yet spawned the machines, we do not
  #     have IP addresses for them, so any unique identifier can be used in
  #     lieu of IP addresses.
  # Returns:
  #   An Array of Strings, where each String contains information about the
  #     public IP address, private IP address, and roles that the new machines
  #     have taken on.
  def start_new_roles_on_nodes_in_cloud(ips_to_roles)
    Djinn.log_info("Starting new roles in cloud with following info: " +
      "#{ips_to_roles.inspect}")

    keyname = @options['keyname']
    num_of_vms = ips_to_roles.keys.length
    roles = ips_to_roles.values
    disks = Array.new(size=num_of_vms, obj=nil)  # no persistent disks
    Djinn.log_info("Need to spawn up #{num_of_vms} VMs")
    imc = InfrastructureManagerClient.new(@@secret)

    begin
      new_nodes_info = imc.spawn_vms(num_of_vms, @options, roles, disks)
    rescue FailedNodeException, AppScaleException => exception
      Djinn.log_error("Couldn't spawn #{num_of_vms} VMs with roles #{roles} " +
        "because: #{exception.message}")
      return []
    end

    # initialize them and wait for them to start up
    Djinn.log_debug("info about new nodes is " +
      "[#{new_nodes_info.join(', ')}]")

    add_nodes(new_nodes_info)
    update_hosts_info()

    if my_node.is_login?
      regenerate_nginx_config_files()
    end

    return new_nodes_info
  end


  # This method takes a list of IP addresses that correspond to machines
  # with AppScale installed on them, that have passwordless SSH already
  # set up (presumably by appscale-add-instances). The machines are added
  # to the currently running AppScale deployment, and are then assigned
  # the roles given to us by the caller.
  # Args:
  #   ips_to_roles: A Hash that maps machines to the roles that should be
  #     started on them. Machines are uniquely identified by their IP
  #     address, which is assumed to be reachable from any node in the
  #     AppScale deployment.
  # Returns:
  #   An Array of Strings, where each String contains information about the
  #     public IP address, private IP address, and roles that the new machines
  #     have taken on.
  def start_new_roles_on_nodes_in_xen(ips_to_roles)
    Djinn.log_info("Starting new roles in virt with following info: " +
      "#{ips_to_roles.inspect}")

    nodes_info = []
    keyname = @options['keyname']
    ips_to_roles.each { |ip, roles|
      Djinn.log_info("Will add roles #{roles.join(', ')} to new " +
        "node at IP address #{ip}")
      nodes_info << {
        "public_ip" => ip,
        "private_ip" => ip,
        "jobs" => roles,
        "disk" => nil
      }
    }

    add_nodes(nodes_info)
    update_hosts_info()

    if my_node.is_login?
      regenerate_nginx_config_files()
    end

    return nodes_info
  end


  # Starts the given roles by using open nodes, spawning new nodes, or some
  # combination of the two. 'nodes_needed' should be an Array, where each
  # item is an Array of the roles to start on each node.
  def start_new_roles_on_nodes(nodes_needed, instance_type, secret)
     if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    if nodes_needed.class != Array
      Djinn.log_error("Was expecting nodes_needed to be an Array, not " +
        "a #{nodes_needed.class}")
      return BAD_INPUT_MSG
    end

    Djinn.log_info("Received a request to acquire nodes with roles " +
      "#{nodes_needed.join(', ')}, with instance type #{instance_type} for " +
      "new nodes")

    vms_to_use = []
    ZKInterface.lock_and_run {
      num_of_vms_needed = nodes_needed.length

      @nodes.each_with_index { |node, index|
        if node.is_open?
          Djinn.log_info("Will use node #{node} to run new roles")
          node.jobs = nodes_needed[vms_to_use.length]
          vms_to_use << node

          if vms_to_use.length == nodes_needed.length
            Djinn.log_info("Only using open nodes to run new roles")
            break
          end
        end
      }

      vms_to_spawn = nodes_needed.length - vms_to_use.length

      if vms_to_spawn > 0 and !is_cloud?
        Djinn.log_error("Still need #{vms_to_spawn} more nodes, but we " +
        "aren't in a cloud environment, so we can't acquire more nodes - " +
        "failing the caller's request.")
        return NOT_ENOUGH_OPEN_NODES
      end

      if vms_to_spawn > 0
        Djinn.log_info("Need to spawn up #{vms_to_spawn} VMs")
        # Make sure the user has said it is ok to add more VMs before doing so.
        allowed_vms = Integer(@options['max_images']) - @nodes.length
        if allowed_vms < vms_to_spawn
          Djinn.log_info("Can't spawn up #{vms_to_spawn} VMs, because that " +
            "would put us over the user-specified limit of #{@options['max_images']} " +
            "VMs. Instead, spawning up #{allowed_vms}.")
          vms_to_spawn = allowed_vms
          if vms_to_spawn.zero?
            Djinn.log_error("Reached the maximum number of VMs that we " +
              "can use in this cloud deployment, so not spawning more nodes.")
            return "Reached maximum number of VMs we can use."
          end
        end

        disks = Array.new(size=vms_to_spawn, obj=nil)  # no persistent disks

        # start up vms_to_spawn vms as open
        imc = InfrastructureManagerClient.new(@@secret)
        begin
          new_nodes_info = imc.spawn_vms(vms_to_spawn, @options, "open", disks)
        rescue FailedNodeException, AppScaleException => exception
          Djinn.log_error("Couldn't spawn #{vms_to_spawn} VMs with roles " +
            "open because: #{exception.message}")
          return exception.message
        end


        # initialize them and wait for them to start up
        Djinn.log_debug("info about new nodes is " +
          "[#{new_nodes_info.join(', ')}]")
        add_nodes(new_nodes_info)

        # add information about the VMs we spawned to our list, which may
        # already have info about the open nodes we want to use
        new_nodes = Djinn.convert_location_array_to_class(new_nodes_info,
          @options['keyname'])
        vms_to_use << new_nodes
        vms_to_use.flatten!
      end
    }

    wait_for_nodes_to_finish_loading(vms_to_use)

    nodes_needed.each_index { |i|
      begin
        ZKInterface.add_roles_to_node(nodes_needed[i], vms_to_use[i],
          @options['keyname'])
        Djinn.log_info("Added roles #{nodes_needed[i].join(', ')} " +
          "to virtual machine #{vms_to_use[i]}")
      rescue FailedZooKeeperOperationException => e
        Djinn.log_warn("(start_new_roles_on_nodes) couldn't talk to " +
          "zookeeper while adding roles with #{e.message}.")
      end
    }

    wait_for_nodes_to_finish_loading(vms_to_use)

    return "OK"
  end


  # Given an Array of Strings containing information about machines with
  # AppScale installed on them, copies over deployment-specific files
  # and starts the AppController on them. Each AppController is then
  # instructed to start a specific set of roles, and join the existing
  # AppScale deployment.
  # Args:
  #   node_info: An Array of Strings, where each String has information
  #     about a node to add to the current AppScale deployment (e.g.,
  #     IP addresses, roles to run).
  def add_nodes(node_info)
    keyname = @options['keyname']
    new_nodes = Djinn.convert_location_array_to_class(node_info, keyname)

    # Since an external thread can modify @nodes, let's put a lock around
    # it to prevent race conditions.
    @state_change_lock.synchronize {
      @nodes.concat(new_nodes)
      @nodes.uniq!
    }
    Djinn.log_debug("Changed nodes to #{@nodes}")

    update_firewall()
    initialize_nodes_in_parallel(new_nodes)
  end


  # Cleans out temporary files that may have been written by a previous
  # AppScale deployment.
  def erase_old_data()
    Djinn.log_run("rm -rf #{Dir.tmpdir}/h*")
    Djinn.log_run("rm -f ~/.appscale_cookies")

    Nginx.clear_sites_enabled()
    HAProxy.clear_sites_enabled()
    Djinn.log_run("echo '' > /root/.ssh/known_hosts") # empty it out but leave the file there
    CronHelper.clear_app_crontabs
  end


  def wait_for_nodes_to_finish_loading(nodes)
    Djinn.log_info("Waiting for nodes to finish loading")

    nodes.each { |node|
      if ZKInterface.is_node_done_loading?(node.public_ip)
        Djinn.log_info("Node at #{node.public_ip} has finished loading.")
        next
      else
        Djinn.log_info("Node at #{node.public_ip} has not yet finished " +
          "loading - will wait for it to finish.")
        Kernel.sleep(SMALL_WAIT)
        redo
      end
    }

    Djinn.log_info("Nodes have finished loading")
    return
  end


  # This method logs a message that is useful to know when debugging AppScale,
  # but is too extraneous to know when AppScale normally runs.
  #
  # Messages are logged both to STDOUT as well as to @@logs_buffer, which is
  # sent to the AppDashboard for viewing via a web UI.
  #
  # Args:
  #   message: A String containing the message to be logged.
  def self.log_debug(message)
    @@log.debug(message)
    self.log_to_buffer(Logger::DEBUG, message)
  end


  # This method logs a message that is useful to know when AppScale normally
  # runs.
  #
  # Args:
  #   message: A String containing the message to be logged.
  def self.log_info(message)
    @@log.info(message)
    self.log_to_buffer(Logger::INFO, message)
  end


  # This method logs a message that is useful to know when the AppController
  # experiences an unexpected event.
  #
  # Args:
  #   message: A String containing the message to be logged.
  def self.log_warn(message)
    @@log.warn(message)
    self.log_to_buffer(Logger::WARN, message)
  end


  # This method logs a message that corresponds to an erroneous, but
  # recoverable, event.
  #
  # Args:
  #   message: A String containing the message to be logged.
  def self.log_error(message)
    @@log.error(message)
    self.log_to_buffer(Logger::ERROR, message)
  end


  # This method logs a message that immediately precedes the death of this
  # AppController.
  #
  # Args:
  #   message: A String containing the message to be logged.
  def self.log_fatal(message)
    @@log.fatal(message)
    self.log_to_buffer(Logger::FATAL, message)
  end

  # Use syslogd to log a message to the combined application log.
  #
  # Args:
  #   app_id: A String containing the app ID.
  #   message: A String containing the message to log.
  def self.log_app_error(app_id, message)
    Syslog.open("app___#{app_id}") { |s| s.err message }
  end

  # Appends this log message to a buffer, which will be periodically sent to
  # the AppDashbord.
  #
  # Only sends the message if it has content (as some empty messages are the
  # result of exec'ing commands that produce no output), and if its log level
  # is at least as great as the log level that we want to capture logs for.
  #
  # Args:
  #   level: An Integer in the set of Logger levels (e.g., Logger::DEBUG,
  #     Logger::INFO) that indicates the severity of this log message.
  #   message: A String containing the message to be logged.
  def self.log_to_buffer(level, message)
    return if message.empty?
    return if level < @@log.level
    time = Time.now
    @@logs_buffer << {
      'timestamp' => time.to_i,
      'level' => level + 1,  # Python and Java are one higher than Ruby
      'message' => message
    }
    return
  end


  # Logs and runs the given command, which is assumed to be trusted and thus
  # needs no filtering on our part. Obviously this should not be executed by
  # anything that the user could inject input into. Returns the output of
  # the command that was executed.
  def self.log_run(command)
    Djinn.log_debug("Running #{command}")
    output = `#{command}`
    Djinn.log_debug("Output of #{command} was: #{output}")
    return output
  end


  # This method converts an Array of Strings (where each String contains all the
  # information about a single node) to an Array of DjinnJobData objects, which
  # provide convenience methods that make them easier to operate on than just
  # raw String objects.
  def self.convert_location_array_to_class(nodes, keyname)
    array_of_nodes = []
    nodes.each { |node|
      converted = DjinnJobData.new(node, keyname)
      array_of_nodes << converted
    }

    return array_of_nodes
  end


  # This method is the opposite of the previous method, and is needed when an
  # AppController wishes to pass node information to other AppControllers via
  # SOAP (as SOAP accepts Arrays and Strings but not DjinnJobData objects).
  def self.convert_location_class_to_array(djinn_locations)
    if djinn_locations.class != Array
      @state = "Locations is not an Array, not a #{djinn_locations.class}."
      HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
    end

    djinn_loc_array = []
    djinn_locations.each { |location|
      djinn_loc_array << location.to_hash
    }
    return JSON.dump(djinn_loc_array)
  end

  def get_login()
    @nodes.each { |node|
      return node if node.is_login?
    }

    @state = "No login nodes found."
    HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
  end

  def get_shadow()
    @nodes.each { |node|
      return node if node.is_shadow?
    }

    @state = "No shadow nodes found."
    HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
  end

  def get_db_master()
    @nodes.each { |node|
      return node if node.is_db_master?
    }

    @state = "No DB master nodes found."
    HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
  end

  def self.get_db_master_ip()
    masters_file = File.expand_path("#{APPSCALE_CONFIG_DIR}/masters")
    master_ip = HelperFunctions.read_file(masters_file)
    return master_ip
  end

  def self.get_db_slave_ips()
    slaves_file = File.expand_path("#{APPSCALE_CONFIG_DIR}/slaves")
    slave_ips = File.open(slaves_file).readlines.map { |f| f.chomp! }
    slave_ips = [] if slave_ips == [""]
    return slave_ips
  end

  def get_all_appengine_nodes()
    ae_nodes = []
    @nodes.each { |node|
      if node.is_appengine?
        ae_nodes << node.private_ip
      end
    }
    return ae_nodes
  end

  def get_load_balancer_ip()
    @nodes.each { |node|
      if node.is_load_balancer?
        return node.public_ip
      end
    }
  end

  def valid_secret?(secret)
    @@secret = HelperFunctions.get_secret
    if secret != @@secret
      failed_match_msg = "Incoming secret [#{secret}] failed to match " + \
        " known secret [#{@@secret}]"
      Djinn.log_error(failed_match_msg)
    end
    return secret == @@secret
  end

  def get_public_ip(private_ip)
    return private_ip unless is_cloud?

    keyname = @options['keyname']
    infrastructure = @options['infrastructure']

    Djinn.log_debug("Looking for #{private_ip}")
    private_ip = HelperFunctions.convert_fqdn_to_ip(private_ip)
    Djinn.log_debug("[converted] Looking for #{private_ip}")
    @nodes.each { |node|
      node_private_ip = HelperFunctions.convert_fqdn_to_ip(node.private_ip)
      node_public_ip = HelperFunctions.convert_fqdn_to_ip(node.public_ip)

      if node_private_ip == private_ip or node_public_ip == private_ip
        return node_public_ip
      end
    }

    Djinn.log_fatal("get public ip] Couldn't convert private " +
      "IP #{private_ip} to a public address.")
    HelperFunctions.log_and_crash("[get public ip] Couldn't convert private " +
      "IP #{private_ip} to a public address.")
  end

  # Collects all AppScale-generated logs from all machines, and places them in
  # a tarball in the AppDashboard running on this machine. This enables users
  # to download it for debugging purposes.
  #
  # Args:
  #   secret: A String password that is used to authenticate SOAP callers.
  def gather_logs(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    uuid = HelperFunctions.get_random_alphanumeric()
    Djinn.log_info("Generated uuid #{uuid} for request to gather logs.")

    Thread.new {
      # Begin by copying logs on all machines to this machine.
      local_log_dir = "#{Dir.tmpdir}/#{uuid}"
      remote_log_dir = "/var/log/appscale"
      FileUtils.mkdir_p(local_log_dir)
      @nodes.each { |node|
        this_nodes_logs = "#{local_log_dir}/#{node.private_ip}"
        FileUtils.mkdir_p(this_nodes_logs)
        Djinn.log_run("scp -r -i #{node.ssh_key} -o StrictHostkeyChecking=no " +
          "2>&1 root@#{node.private_ip}:#{remote_log_dir} #{this_nodes_logs}")
      }

      # Next, tar.gz it up in the dashboard app so that users can download it.
      dashboard_log_location = "#{HelperFunctions.get_app_path(AppDashboard::APP_NAME)}/app/static/download-logs/#{uuid}.tar.gz"
      Djinn.log_info("Done gathering logs - placing logs at " +
        dashboard_log_location)
      Djinn.log_run("tar -czf #{dashboard_log_location} #{local_log_dir}")
      FileUtils.rm_rf(local_log_dir)
    }

    return uuid
  end


  # Instructs Nginx and HAProxy to begin routing traffic for the named
  # application to a new AppServer.
  #
  # This method should be called at the AppController running the login role,
  # as it is the node that receives application traffic from the outside.
  #
  # Args:
  #   app_id: A String that identifies the application that runs the new
  #     AppServer.
  #   ip: A String that identifies the private IP address where the new
  #     AppServer runs.
  #   port: A Fixnum that identifies the port where the new AppServer runs at
  #     ip.
  #   secret: A String that is used to authenticate the caller.
  #
  # Returns:
  #   "OK" if the addition was successful. In case of failures, the following
  #   Strings may be returned:
  #   - BAD_SECRET_MSG: If the caller cannot be authenticated.
  #   - NO_HAPROXY_PRESENT: If this node does not run HAProxy (and thus cannot
  #     add AppServers to HAProxy config files).
  #   - NOT_READY: If this node runs HAProxy, but hasn't allocated ports for
  #     it and nginx yet. Callers should retry at a later time.
  def add_routing_for_appserver(app_id, ip, port, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    if !my_node.is_login?
      return NO_HAPROXY_PRESENT
    end

    if @app_info_map[app_id].nil? or @app_info_map[app_id]['appengine'].nil?
      return NOT_READY
    elsif @app_info_map[app_id]['appengine'].include?("#{ip}:#{port}")
      Djinn.log_warn("Already registered AppServer for app #{app_id} at #{ip}:#{port}.")
      return INVALID_REQUEST
    end

    Djinn.log_debug("Adding AppServer for app #{app_id} at #{ip}:#{port}.")

    # Find and remove an entry for this appserver node and app.
    APPS_LOCK.synchronize {
      match = @app_info_map[app_id]['appengine'].index("#{ip}:-1")
      if match
        @app_info_map[app_id]['appengine'].delete_at(match)
      else
        Djinn.log_warn("Received a no matching request for: #{ip}:#{port}.")
      end
      @app_info_map[app_id]['appengine'] << "#{ip}:#{port}"
    }

    HAProxy.update_app_config(my_node.private_ip, app_id,
      @app_info_map[app_id])

    unless Nginx.is_app_already_configured(app_id)
      # Get static handlers and make sure cache path is readable.
      begin
        static_handlers = HelperFunctions.parse_static_data(app_id)
        Djinn.log_run("chmod -R +r #{HelperFunctions.get_cache_path(app_id)}")
      rescue => e
        # This specific exception may be a JSON parse error.
        error_msg = "ERROR: Unable to parse app.yaml file for #{app_id}. "\
          "Exception of #{e.class} with message #{e.message}"
        place_error_app(app_id, error_msg, @app_info_map[app_id]['language'])
        static_handlers = []
      end

      http_port = @app_info_map[app_id]['nginx']
      https_port = @app_info_map[app_id]['nginx_https']

      # Make sure the Nginx port is opened after HAProxy is configured.
      Nginx.write_fullproxy_app_config(
        app_id,
        http_port,
        https_port,
        my_node.public_ip,
        my_node.private_ip,
        @app_info_map[app_id]['haproxy'],
        static_handlers,
        get_login.private_ip,
        @app_info_map[app_id]['language']
      )

      uac = UserAppClient.new(my_node.private_ip, @@secret)
      loop {
        success = uac.add_instance(app_id, my_node.public_ip,
          http_port, https_port)
        if success
          Djinn.log_info("Committed application info for #{app_id} " +
            "to user_app_server")
        end
        begin
          if success
            # tell ZK that we are hosting the app in case we die, so that
            # other nodes can update the UserAppServer on its behalf
            ZKInterface.add_app_instance(app_id, my_node.public_ip, http_port)
            break
          end
        rescue FailedZooKeeperOperationException
          Djinn.log_info("Couldn't talk to zookeeper while trying " +
            "to add instance for application #{app_id}: retrying.")
        end
        Kernel.sleep(SMALL_WAIT)
      }
      Djinn.log_info("Done setting full proxy for #{app_id}.")
    end

    return "OK"
  end

  # Instruct HAProxy to begin routing traffic to the BlobServers.
  #
  # Args:
  #   secret: A String that is used to authenticate the caller.
  #
  # Returns:
  #   "OK" if the addition was successful. In case of failures, the following
  #   Strings may be returned:
  #   - BAD_SECRET_MSG: If the caller cannot be authenticated.
  #   - NO_HAPROXY_PRESENT: If this node does not run HAProxy.
  def add_routing_for_blob_server(secret)
    unless valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    unless my_node.is_login?
      return NO_HAPROXY_PRESENT
    end

    Djinn.log_debug('Adding BlobServer routing.')
    servers = []
    get_all_appengine_nodes.each { |ip|
      servers << {'ip' => ip, 'port' => BlobServer::SERVER_PORT}
    }
    HAProxy.create_app_config(servers, my_node.private_ip,
      BlobServer::HAPROXY_PORT, BlobServer::NAME)
  end

  # Instructs HAProxy to stop routing traffic for the named application to
  # the AppServer at the given location.
  #
  # This method should be called at the AppController running the login role,
  # as it is the only node that runs haproxy.
  #
  # Args:
  #   app_id: A String that identifies the application that runs the AppServer
  #     to remove.
  #   ip: A String that identifies the private IP address where the AppServer
  #     to remove runs.
  #   port: A Fixnum that identifies the port where the AppServer was running
  #     at ip.
  #   secret: A String that is used to authenticate the caller.
  #
  # Returns:
  #   "OK" if the removal was successful. In case of failures, the following
  #   Strings may be returned:
  #   - BAD_SECRET_MSG: If the caller cannot be authenticated.
  #   - NO_HAPROXY_PRESENT: If this node does not run HAProxy (and thus cannot
  #     remove AppServers from HAProxy config files).
  def remove_appserver_from_haproxy(app_id, ip, port, secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    if !my_node.is_login?
      return NO_HAPROXY_PRESENT
    end

    Djinn.log_info("Removing AppServer for app #{app_id} at #{ip}:#{port}")
    if @app_info_map[app_id] and @app_info_map[app_id]['appengine']
      @app_info_map[app_id]['appengine'].delete("#{ip}:#{port}")
      HAProxy.update_app_config(my_node.private_ip, app_id,
        @app_info_map[app_id])
    else
      Djinn.log_debug("AppServer #{app_id} at #{ip}:#{port} is not known.")
    end

    return "OK"
  end

  # Creates an Nginx/HAProxy configuration file for the Users/Apps soap server.
  def configure_uaserver()
    all_db_private_ips = []
    @nodes.each { | node |
      if node.is_db_master? or node.is_db_slave?
        all_db_private_ips.push(node.private_ip)
      end
    }
    HAProxy.create_ua_server_config(all_db_private_ips,
      my_node.private_ip, UserAppClient::HAPROXY_SERVER_PORT)
    Nginx.create_uaserver_config(my_node.private_ip)
    Nginx.reload()
  end

  def configure_db_nginx()
    all_db_private_ips = []
    @nodes.each { | node |
      if node.is_db_master? or node.is_db_slave?
        all_db_private_ips.push(node.private_ip)
      end
    }
    Nginx.create_datastore_server_config(all_db_private_ips, DatastoreServer::PROXY_PORT)
    Nginx.reload()
  end


  def write_database_info()
    table = @options['table']
    replication = @options['replication']
    keyname = @options['keyname']

    tree = { :table => table, :replication => replication, :keyname => keyname }
    db_info_path = "#{APPSCALE_CONFIG_DIR}/database_info.yaml"
    File.open(db_info_path, "w") { |file| YAML.dump(tree, file) }

    num_of_nodes = @nodes.length
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/num_of_nodes", "#{num_of_nodes}\n")
  end


  def update_firewall()
    all_ips = []
    @nodes.each { |node|
      if !all_ips.include? node.private_ip
        all_ips << node.private_ip
      end
    }
    all_ips << "\n"
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/all_ips", all_ips.join("\n"))
    Djinn.log_debug("Letting the following IPs through the firewall: " +
      all_ips.join(', '))

    # Re-run the filewall script here since we just wrote the all_ips file
    if FIREWALL_IS_ON
      Djinn.log_run("bash #{APPSCALE_HOME}/firewall.conf")
    end
  end



  def backup_appcontroller_state()
    state = {'@@secret' => @@secret }
    instance_variables.each { |k|
      v = instance_variable_get(k)
      if k.to_s == "@nodes"
        v = Djinn.convert_location_class_to_array(v)
      elsif k == "@my_index" or k == "@api_status"
        # Don't back up @my_index - it's a node-specific pointer that
        # indicates which node is "our node" and thus should be regenerated
        # via find_me_in_locations.
        # Also don't worry about @api_status - (used to be for deprecated
        # API checker) it can take up a lot of space and can easily be
        # regenerated with new data.
        next
      end

      state[k] = v
    }

    Djinn.log_debug("backup_appcontroller_state:"+state.to_s)

    begin
      ZKInterface.write_appcontroller_state(state)
    rescue FailedZooKeeperOperationException => e
      Djinn.log_warn("Couldn't talk to zookeeper whle backing up " +
        "appcontroller state with #{e.message}.")
    end
  end

  # Restores the state of each of the instance variables that the AppController
  # holds by pulling it from ZooKeeper (previously populated by the Shadow
  # node, who always has the most up-to-date version of this data).
  #
  # Returns:
  #   A boolean to indicate if we were able to restore the state.
  def restore_appcontroller_state()
    Djinn.log_info("Restoring AppController state")
    json_state=""

    if !File.exists?(ZK_LOCATIONS_FILE)
      Djinn.log_info("#{ZK_LOCATIONS_FILE} doesn't exist: not restoring data.")
      return false
    end

    loop {
      begin
        json_state = ZKInterface.get_appcontroller_state()
      rescue => e
        Djinn.log_debug("Saw exception #{e.message} reading appcontroller state.")
        json_state = ""
        Kernel.sleep(SMALL_WAIT)
      end
      break if !json_state.empty?
      Djinn.log_warn("Unable to get state from zookeeper: trying again.")
      pick_zookeeper(@zookeeper_data)
    }
    Djinn.log_info("Reload State : #{json_state}")

    @@secret = json_state['@@secret']
    keyname = json_state['@options']['keyname']

    # Puts json_state.
    json_state.each { |k, v|
      next if k == "@@secret"
      if k == "@nodes"
        v = Djinn.convert_location_array_to_class(JSON.load(v), keyname)
      end
      # my_private_ip and my_public_ip instance variables are from the head
      # node. This node may or may not be the head node, so set those
      # from local files. state_change_lock is a Monitor: no need to
      # restore it.
      if k == "@my_private_ip"
        @my_private_ip = HelperFunctions.read_file("#{APPSCALE_CONFIG_DIR}/my_private_ip").chomp
      elsif k == "@my_public_ip"
        @my_public_ip = HelperFunctions.read_file("#{APPSCALE_CONFIG_DIR}/my_public_ip").chomp
      elsif DEPLOYMENT_STATE.include?(k)
        instance_variable_set(k, v)
      end
    }

    # Check to see if our IP address has changed. If so, we need to update all
    # of our internal state to use the new public and private IP anywhere the
    # old ones were present.
    if !HelperFunctions.get_all_local_ips().include?(@my_private_ip)
      Djinn.log_info("IP changed old private:#{@my_private_ip} public:#{@my_public_ip}.")
      update_state_with_new_local_ip()
      Djinn.log_info("IP changed new private:#{@my_private_ip} public:#{@my_public_ip}.")
    end
    Djinn.log_debug("app_info_map after restore is #{@app_info_map}.")

    # Now that we've restored our state, update the pointer that indicates
    # which node in @nodes is ours
    find_me_in_locations()

    return true
  end


  # Updates all instance variables stored within the AppController with the new
  # public and private IP addreses of this machine.
  #
  # The issue here is that an AppController may back up state when running, but
  # when it is restored, its IP address changes (e.g., when taking AppScale down
  # then starting it up on new machines in a cloud deploy). This method searches
  # through internal AppController state to update any place where the old
  # public and private IP addresses were used, replacing them with the new one.
  def update_state_with_new_local_ip()
    # First, find out this machine's private IP address. If multiple eth devices
    # are present, use the same one we used last time.
    all_local_ips = HelperFunctions.get_all_local_ips()
    new_private_ip = all_local_ips[@eth_interface]

    # Next, find out this machine's public IP address. In a cloud deployment, we
    # have to rely on the metadata server, while in a cluster deployment, it's
    # the same as the private IP.
    if ["ec2", "euca", "gce"].include?(@options['infrastructure'])
      new_public_ip = HelperFunctions.get_public_ip_from_metadata_service()
    else
      new_public_ip = new_private_ip
    end

    # Finally, replace anywhere that the old public or private IP addresses were
    # used with the new one.
    old_public_ip = @my_public_ip
    old_private_ip = @my_private_ip

    @nodes.each { |node|
      if node.public_ip == old_public_ip
        node.public_ip = new_public_ip
      end

      if node.private_ip == old_private_ip
        node.private_ip = new_private_ip
      end
    }

    if @options['hostname'] == old_public_ip
      @options['hostname'] = new_public_ip
    end

    if !is_cloud?
      nodes = JSON.load(@options['ips'])
      nodes.each { |node|
        if node['ip'] == old_private_ip
          node['ip'] == new_private_ip
        end
      }
      @options['ips'] = JSON.dump(nodes)
    end

    @app_info_map.each { |appid, app_info|
      if app_info['appengine'].nil?
        next
      end

      changed = false
      new_app_info = []
      app_info['appengine'].each { |location|
        host, port = location.split(":")
        if host == old_private_ip
          host = new_private_ip
          changed = true
        end
        new_app_info << "#{host}:#{port}"

        if changed
          app_info['appengine'] = new_app_info
        end
      }
    }

    @all_stats = []

    @my_public_ip = new_public_ip
    @my_private_ip = new_private_ip
  end


  # Updates the file that says where all the ZooKeeper nodes are
  # located so that this node has the most up-to-date info if it needs to
  # restore the data down the line.
  def write_zookeeper_locations()
    zookeeper_data = { 'last_updated_at' => @last_updated,
      'locations' => []
    }

    @nodes.each { |node|
      if node.is_zookeeper?
        if !zookeeper_data['locations'].include? node.private_ip
          zookeeper_data['locations'] << node.private_ip
        end
      end
    }

    # Let's see if it changed since last time we got the list.
    zookeeper_data['locations'].sort!
    if zookeeper_data['locations'] != @zookeeper_data
      # Save the latest list of zookeeper nodes: needed to restart the
      # deployment.
      HelperFunctions.write_json_file(ZK_LOCATIONS_FILE, zookeeper_data)
      @zookeeper_data = zookeeper_data['locations']
      Djinn.log_debug("write_zookeeper_locations: updated list of zookeeper servers")
    end
  end

  # This function makes sure we have a zookeeper connection active to one
  # of the ZK servers.
  def pick_zookeeper(zk_list)
    if zk_list.length < 1
      HelperFunctions.log_and_crash("Don't have valid zookeeper servers.")
    end
    loop {
      break if ZKInterface.is_connected?
      ip = zk_list.sample()
      Djinn.log_info("Trying to use zookeeper server at #{ip}.")
      ZKInterface.init_to_ip(HelperFunctions.local_ip(), ip.to_s)
    }
    Djinn.log_debug("Found zookeeper server.")
  end

  # Backs up information about what this node is doing (roles, apps it is
  # running) to ZooKeeper, for later recovery or updates by other nodes.
  def write_our_node_info()
    # Since more than one AppController could write its data at the same
    # time, get a lock before we write to it.
    begin
      ZKInterface.lock_and_run {
        @last_updated = ZKInterface.add_ip_to_ip_list(my_node.public_ip)
        ZKInterface.write_node_information(my_node, @done_loading)
      }
    rescue => e
      Djinn.log_info("(write_our_node_info) saw exception #{e.message}")
    end

    return
  end


  # Returns the buffer that contains all logs yet to be sent to the Admin
  # Console for viewing.
  #
  # Returns:
  #   An Array of Hashes, where each Hash has information about a single log
  #     line.
  def self.get_logs_buffer()
    return @@logs_buffer
  end


  # Sends all of the logs that have been buffered up to the Admin Console for
  # viewing in a web UI.
  def flush_log_buffer()
    APPS_LOCK.synchronize {
      loop {
        break if @@logs_buffer.empty?
        encoded_logs = JSON.dump({
          'service_name' => 'appcontroller',
          'host' => my_node.public_ip,
          'logs' => @@logs_buffer.shift(LOGS_PER_BATCH),
        })

        # We send logs to dashboard only if controller_logs_to_dashboard
        # is set to True. This will incur in higher traffic to the
        # database, depending on the verbosity and the deployment.
        if @options['controller_logs_to_dashboard'].downcase == "true"
          begin
            url = URI.parse("https://#{get_login.public_ip}:" +
              "#{AppDashboard::LISTEN_SSL_PORT}/logs/upload")
            http = Net::HTTP.new(url.host, url.port)
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
            http.use_ssl = true
            response = http.post(url.path, encoded_logs,
              {'Content-Type'=>'application/json'})
          rescue
            # Don't crash the AppController because we weren't able to send over
            # the logs - just continue on.
          end
        end
      }
    }
  end


  # Sends information about the AppServer processes hosting App Engine apps on
  # this machine to the AppDashboard, for later viewing.
  def send_instance_info_to_dashboard()
    APPS_LOCK.synchronize {
      instance_info = []
      @app_info_map.each_pair { |appid, app_info|
        next if app_info['appengine'].nil?
        app_info['appengine'].each { |location|
          host, port = location.split(":")
          next if Integer(port) < 0
          instance_info << {
            'appid' => appid,
            'host' => host,
            'port' => Integer(port),
            'language' => app_info['language']
          }
        }
      }

      begin
        url = URI.parse("https://#{get_login.public_ip}:" +
          "#{AppDashboard::LISTEN_SSL_PORT}/apps/stats/instances")
        http = Net::HTTP.new(url.host, url.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        response = http.post(url.path, JSON.dump(instance_info),
          {'Content-Type'=>'application/json'})
        Djinn.log_debug("Done sending instance info to AppDashboard. Info is: " +
          "#{instance_info.inspect}. Response is: #{response.body}.")
      rescue OpenSSL::SSL::SSLError, NotImplementedError, Errno::EPIPE,
        Errno::ECONNRESET => e
        backtrace = e.backtrace.join("\n")
        Djinn.log_warn("Error in send_instance_info: #{e.message}\n#{backtrace}")
        retry
      rescue => exception
        # Don't crash the AppController because we weren't able to send over
        # the instance info - just continue on.
        Djinn.log_warn("Couldn't send instance info to the AppDashboard " +
          "because of a #{exception.class} exception.")
      end
    }
  end


  # Informs the AppDashboard that the named AppServer is no longer running, so
  # that it no longer displays that AppServer in its instance information.
  #
  # Args:
  #   appid: A String that names the application whose AppServer was removed.
  #   location: A String that identifies the host and port that the AppServer
  #     was removed off of.
  def delete_instance_from_dashboard(appid, location)
    begin
      host, port = location.split(":")
      instance_info = [{
        'appid' => appid,
        'host' => host,
        'port' => Integer(port)
      }]

      url = URI.parse("https://#{get_login.public_ip}:" +
        "#{AppDashboard::LISTEN_SSL_PORT}/apps/stats/instances")
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      request = Net::HTTP::Delete.new(url.path)
      request.body = JSON.dump(instance_info)
      response = http.request(request)
      Djinn.log_debug("Sent delete_instance to AppDashboard. Info is: " +
        "#{instance_info.inspect}. Response is: #{response.body}.")
    rescue => exception
      # Don't crash the AppController because we weren't able to send over
      # the instance info - just continue on.
      Djinn.log_warn("Couldn't delete instance info to AppDashboard because" +
        " of a #{exception.class} exception.")
    end
  end


  # Queries ZooKeeper to see if our local copy of @nodes is out of date and
  # should be regenerated with up to date data from ZooKeeper. If data on
  # our node has changed, this starts or stops the necessary roles.
  def update_local_nodes()
    begin
      ZKInterface.lock_and_run {
        # See if the ZooKeeper data is newer than ours - if not, don't
        # update anything and return.
        zk_ips_info = ZKInterface.get_ip_info()
        if zk_ips_info["last_updated"] <= @last_updated
          return false
        else
          Djinn.log_info("Updating data from ZK. Our timestamp, " +
            "#{@last_updated}, was older than the ZK timestamp, " +
            "#{zk_ips_info['last_updated']}")
        end

        all_ips = zk_ips_info["ips"]
        new_nodes = []
        all_ips.each { |ip|
          new_nodes << DjinnJobData.new(ZKInterface.get_job_data_for_ip(ip),
            @options['keyname'])
        }

        old_roles = my_node.jobs
        @state_change_lock.synchronize {
          @nodes = new_nodes.uniq
        }

        find_me_in_locations()
        new_roles = my_node.jobs

        Djinn.log_info("My new nodes are [#{@nodes.join(', ')}], and my new " +
          "node is #{my_node}")

        # Since we're about to possibly load and unload roles, set done_loading
        # for our node to false, so that other nodes don't erroneously send us
        # additional roles to do while we're in this state where lots of side
        # effects are happening.
        @done_loading = false
        ZKInterface.set_done_loading(my_node.public_ip, false)

        roles_to_start = new_roles - old_roles
        if !roles_to_start.empty?
          Djinn.log_info("Need to start [#{roles_to_start.join(', ')}] " +
            "roles on this node")
          roles_to_start.each { |role|
            Djinn.log_info("Starting role #{role}")

            # When starting the App Engine role, we need to make sure that we load
            # all the App Engine apps on this machine.
            if role == "appengine"
              @apps_loaded = []
            end
            send("start_#{role}".to_sym)
          }
        end

        roles_to_stop = old_roles - new_roles
        if !roles_to_stop.empty?
          Djinn.log_info("Need to stop [#{roles_to_stop.join(', ')}] " +
            "roles on this node")
          roles_to_stop.each { |role|
            send("stop_#{role}".to_sym)
          }
        end

        # And now that we're done loading/unloading roles, set done_loading for
        # our node back to true.
        ZKInterface.set_done_loading(my_node.public_ip, true)
        @done_loading = true

        @last_updated = zk_ips_info['last_updated']

        # Finally, since the node layout changed, there may be a change in the
        # list of AppServers, so update nginx / haproxy accordingly.
        if my_node.is_login?
          regenerate_nginx_config_files()
        end
      }
    rescue => e
      Djinn.log_warn("(update_local_node) saw exception #{e.message}")
      return false
    end

    return true
  end


  def remove_app_hosting_data_for_node(ip)
    instances_to_delete = ZKInterface.get_app_instances_for_ip(ip)
    uac = UserAppClient.new(my_node.private_ip, @@secret)
    instances_to_delete.each { |instance|
      Djinn.log_info("Deleting app instance for app #{instance['app_name']}" +
        " located at #{instance['ip']}:#{instance['port']}")
      begin
        uac.delete_instance(instance['app_name'], instance['ip'],
          instance['port'])
      rescue FailedNodeException
        Djinn.log_warn("Coulnd't talk to #{ip} to stop all applications")
      end
    }
  end


  # Removes information associated with the given IP address from our local
  # cache (@nodes) as well as the remote node storage mechanism (in ZooKeeper).
  def remove_node_from_local_and_zookeeper(ip)
    # First, remove our local copy
    index_to_remove = nil
    @nodes.each_index { |i|
      if @nodes[i].public_ip == ip
        index_to_remove = i
        break
      end
    }
    @state_change_lock.synchronize {
      @nodes.delete(@nodes[index_to_remove])
    }

    # Then remove the remote copy
    begin
      ZKInterface.remove_node_information(ip)
      @last_updated = ZKInterface.remove_ip_from_ip_list(ip)
    rescue FailedZooKeeperOperationException => e
      Djinn.log_warn("(remove_node_from_local_and_zookeeper) issues " +
        "talking to zookeeper with #{e.message}.")
    end
  end


  def wait_for_data()
    loop {
      break if got_all_data()
      if @kill_sig_received
        Djinn.log_fatal("Received kill signal, aborting startup")
        HelperFunctions.log_and_crash("Received kill signal, aborting startup")
      else
        Djinn.log_info("Waiting for data from the load balancer or cmdline tools")
        Kernel.sleep(SMALL_WAIT)
      end
    }

  end

  def parse_options
    if @options['appengine']
      @num_appengines = Integer(@options['appengine'])
    end

    # Set the proper log level.
    @@log.level = Logger::DEBUG if @options['verbose'].downcase == "true"

    keypath = @options['keyname'] + ".key"
    Djinn.log_debug("Keypath is #{keypath}, keyname is #{@options['keyname']}")
    my_key_dir = "#{APPSCALE_CONFIG_DIR}/keys/#{my_node.cloud}"
    my_key_loc = "#{my_key_dir}/#{keypath}"
    Djinn.log_debug("Creating directory #{my_key_dir} for my ssh key #{my_key_loc}")
    FileUtils.mkdir_p(my_key_dir)
    Djinn.log_run("cp #{APPSCALE_CONFIG_DIR}/ssh.key #{my_key_loc}")

    if is_cloud?
      # for euca
      ENV['EC2_ACCESS_KEY'] = @options['ec2_access_key']
      ENV['EC2_SECRET_KEY'] = @options['ec2_secret_key']
      ENV['EC2_URL'] = @options['ec2_url']

      # for ec2
      cloud_keys_dir = File.expand_path("#{APPSCALE_CONFIG_DIR}/keys/cloud1")
      ENV['EC2_PRIVATE_KEY'] = "#{cloud_keys_dir}/mykey.pem"
      ENV['EC2_CERT'] = "#{cloud_keys_dir}/mycert.pem"
    end

    write_database_info()
    update_firewall()
  end

  def got_all_data()
    Djinn.log_debug("[got_all_data]: checking nodes.")
    return false if @nodes == []
    Djinn.log_debug("[got_all_data]: checking options.")
    return false if @options == {}
    Djinn.log_debug("[got_all_data]: checking app_names.")
    return false if @app_names == []
    Djinn.log_debug("[got_all_data]: done.")
    return true
  end


  # If running in a cloud environment, we may be dealing with public and
  # private FQDNs instead of IP addresses, which makes it hard to find out
  # which node is our node (since we find our node by IP). This method
  # looks through all the nodes we currently know of and converts any private
  # FQDNs we see to private IPs.
  #
  # Args:
  #   nodes: An Array of DjinnJobDatas, where each item corresponds to a single
  #     node in this AppScale deployment.
  #
  # Returns:
  #   An Array of DjinnJobDatas, where each item may have its private FQDN
  #   replaced with a private IP address.
  def convert_fqdns_to_ips(nodes)
    if is_cloud?
      Djinn.log_debug("In a cloud deployment, so converting FQDNs -> IPs")
    else
      Djinn.log_debug("Not in a cloud deployment, so not converting FQDNs -> IPs")
      return nodes
    end

    if @options['hostname'] =~ /#{FQDN_REGEX}/
      begin
        @options['hostname'] = HelperFunctions.convert_fqdn_to_ip(@options['hostname'])
      rescue => e
        HelperFunctions.log_and_crash("Failed to convert main hostname #{@options['hostname']}")
      end
    end

    nodes.each { |node|
      # Resolve the private FQDN to a private IP, but don't resolve the public
      # FQDN, as that will just resolve to the private IP.

      pri = node.private_ip
      if pri =~ /#{FQDN_REGEX}/
        begin
          node.private_ip = HelperFunctions.convert_fqdn_to_ip(pri)
        rescue => e
          Djinn.log_info("Failed to convert IP: #{e.message}")
          node.private_ip = node.public_ip
        end
      end
    }

    return nodes
  end


  # Searches through @nodes to try to find out which node is ours. Strictly
  # speaking, we assume that our node is identifiable by private IP, but
  # we also check our public IPs (for AWS and GCE) in case the user got it
  # wrong.
  def find_me_in_locations()
    @my_index = nil
    all_local_ips = HelperFunctions.get_all_local_ips()
    Djinn.log_debug("Searching for a node with any of these private IPs: " +
      "#{all_local_ips.join(', ')}")
    Djinn.log_debug("All nodes are: #{@nodes.join(', ')}")

    @nodes.each_with_index { |node, index|
      all_local_ips.each_with_index { |ip, eth_interface|
        if ip == node.private_ip
          @my_index = index
          HelperFunctions.set_local_ip(node.private_ip)
          @my_public_ip = node.public_ip
          @my_private_ip = node.private_ip
          @eth_interface = eth_interface
          return
        end
      }
    }

    # We haven't found our ip in the nodes layout: let's try to give
    # better debugging info to the user.
    public_ip = HelperFunctions.get_public_ip_from_metadata_service()
    @nodes.each { |node|
      if node.private_ip == public_ip
        HelperFunctions.log_and_crash("Found my public ip (#{public_ip}) " +
            "but not my private ip in @nodes. Please correct it. @nodes=#{@nodes}")
      end
      if node.public_ip == public_ip
        HelperFunctions.log_and_crash("Found my public ip (#{public_ip}) " +
            "in @nodes but my private ip is not matching! @nodes=#{@nodes}.")
      end
    }

    HelperFunctions.log_and_crash("Can't find my node in @nodes: #{@nodes}. " +
      "My local IPs are: #{all_local_ips.join(', ')}")
  end


  # Checks to see if the credentials given to us (a Hash) have all the keys that
  # other methods expect to see.
  def valid_format_for_credentials(possible_credentials)
    required_fields = ["table", "hostname", "ips", "keyname"]
    required_fields.each { |field|
      if !possible_credentials[field]
        return false
      end
    }

    return true
  end

  def sanitize_credentials()
    newoptions = {}
    @options.each { |key, val|
      if ['ips', 'user_commands'].include?(key)
        newoptions[key] = val
        next
      end

      next unless key.class == String
      newkey = key.gsub(NOT_EMAIL_REGEX, "")
      if newkey.include? "_key" or newkey.include? "EC2_SECRET_KEY"
        if val.class == String
          newval = val.gsub(NOT_FQDN_OR_PLUS_REGEX, "")
        else
          newval = val
        end
      else
        if val.class == String
          newval = val.gsub(NOT_FQDN_REGEX, "")
        else
          newval = val
        end
      end
      newoptions[newkey] = newval
    }
    return newoptions
  end

  # Starts all of the services that this node has been assigned to run.
  # Also starts all services that all nodes run in an AppScale deployment.
  def start_api_services()
    @state = "Starting API Services."
    Djinn.log_info("#{@state}")

    threads = []
    threads << Thread.new {
      if not is_zookeeper_running?
        if my_node.is_zookeeper?
          Djinn.log_info("Starting zookeeper.")
          configure_zookeeper(@nodes, @my_index)
          begin
            start_zookeeper(@options['clear_datastore'].downcase == "true")
          rescue FailedZooKeeperOperationException
            @state = "Couldn't start Zookeeper."
            HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
          end
          Djinn.log_info("Done configuring zookeeper.")
        end
      else
        Djinn.log_info("Zookeeper already running.")
      end
    }

    if my_node.is_db_master? or my_node.is_db_slave?
      threads << Thread.new {
        Djinn.log_info("Starting database services.")
        if my_node.is_db_master?
          start_db_master(@options['clear_datastore'].downcase == "true")
          prime_database
        else
          start_db_slave(@options['clear_datastore'].downcase == "true")
        end
        # Let's make sure cassandra is up.
        HelperFunctions.sleep_until_port_is_open(@my_private_ip,
          THRIFT_PORT)

        # Always colocate the Datastore Server and UserAppServer (soap_server).
        @state = "Starting up SOAP Server and Datastore Server"
        start_datastore_server()

        # Start the UserAppServer and wait till it's ready.
        start_soap_server()
        Djinn.log_info("Done starting database services.")
      }
    end

    # We now wait for the essential services to go up.
    Djinn.log_info("Waiting for DB services ... ")
    threads.each { |t| t.join() }

    # All nodes wait for the UserAppServer now. The call here is just to
    # ensure the UserAppServer is talking to the persistent state.
    HelperFunctions.sleep_until_port_is_open(@my_private_ip,
      UserAppClient::SSL_SERVER_PORT, USE_SSL)
    uac = UserAppClient.new(@my_private_ip, @@secret)
    begin
      app_list = uac.get_all_apps()
    rescue FailedNodeException
      Djinn.log_debug("UserAppServer not ready yet: retrying.")
      retry
    end
    @done_initializing = true
    Djinn.log_info("UserAppServer is ready.")

    # The services below depends directly or indirectly on the UAServer to
    # be operational. So we start them after we test the UAServer.
    threads = []
    if my_node.is_db_master? or my_node.is_db_slave? or my_node.is_zookeeper?
      threads << Thread.new {
        if my_node.is_db_master?
          if @options['clear_datastore'].downcase == "true"
            erase_app_instance_info
          end
        end

        if my_node.is_db_master? or my_node.is_db_slave?
          start_groomer_service()
        end

        start_backup_service()
      }
    end

    if my_node.is_memcache?
      threads << Thread.new {
        start_memcache()
      }
    end

    if my_node.is_login?
      threads << Thread.new {
        start_ejabberd()
      }
    end

    # All nodes have application managers
    threads << Thread.new {
      start_app_manager_server()
    }

    if my_node.is_appengine?
      threads << Thread.new {
        start_blobstore_server()
      }
    end

    if my_node.is_search?
      threads << Thread.new {
        start_search_role()
      }
    end

    if my_node.is_taskqueue_master?
      threads << Thread.new {
        start_taskqueue_master()
      }
    elsif my_node.is_taskqueue_slave?
      threads << Thread.new {
        start_taskqueue_slave()
      }
    end

    # App Engine apps rely on the above services to be started, so
    # join all our threads here
    Djinn.log_info("Waiting for all services to finish starting up")
    threads.each { |t| t.join() }
    Djinn.log_info("API services have started on this node")

    # Login node starts additional services.
    if my_node.is_login?
      update_node_info_cache()
      start_app_dashboard(get_login.public_ip, my_node.private_ip)
      start_hermes()
      TaskQueue.start_flower(@options['flower_password'])
    end
  end


  # Creates database tables in the underlying datastore to hold information
  # about the users that interact with AppScale clouds, and about the
  # applications that AppScale hosts (including data that the apps themselves
  # read and write).
  #
  # Raises:
  #   SystemExit: If the database could not be primed for use with AppScale,
  #     after ten retries.
  def prime_database()
    table = @options['table']
    prime_script = "#{APPSCALE_HOME}/AppDB/#{table}_env/prime_#{table}.py"
    retries = 10
    loop {
      Djinn.log_run("APPSCALE_HOME='#{APPSCALE_HOME}' MASTER_IP='localhost' " +
        "LOCAL_DB_IP='localhost' #{PYTHON27} #{prime_script} " +
        "#{@options['replication']}; echo $? > #{Dir.tmpdir}/retval")
      retval = `cat #{Dir.tmpdir}/retval`.to_i
      return if retval.zero?
      Djinn.log_warn("Failed to prime database. #{retries} retries left.")
      Kernel.sleep(SMALL_WAIT)
      retries -= 1
      break if retries.zero?
    }

    @state = "Failed to prime #{table}."
    HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
  end


  # Delete all apps running on this instance.
  def erase_app_instance_info()
    uac = UserAppClient.new(my_node.private_ip, @@secret)
    begin
      result = uac.delete_all_apps()
      Djinn.log_info("UserAppServer delete_all_apps returned: #{result}.")
    rescue FailedNodeException
      Djinn.log_warn("Couldn't call delete_all_apps from UserAppServer.")
      return
    end
  end


  def start_backup_service()
    BackupRecoveryService.start()
  end

  def start_blobstore_server()
    # Each node has an nginx configuration to reach the datastore. Use it
    # to make sure we are fault-tolerant.
    BlobServer.start(my_node.private_ip, DatastoreServer::LISTEN_PORT_NO_SSL)
    return true
  end

  def start_search_role()
    Search.start_master(@options['clear_datastore'].downcase == "true")
  end

  def start_taskqueue_master()
    TaskQueue.start_master(@options['clear_datastore'].downcase == "true")
    return true
  end


  def start_taskqueue_slave()
    # All slaves connect to the master to start
    master_ip = nil
    @nodes.each { |node|
      master_ip = node.private_ip if node.is_taskqueue_master?
    }

    TaskQueue.start_slave(master_ip, @options['clear_datastore'].downcase == "true")
    return true
  end

  # Starts the application manager which is a SOAP service in charge of
  # starting and stopping applications.
  def start_app_manager_server()
    @state = "Starting up AppManager"
    env_vars = {}
    app_manager_script = "#{APPSCALE_HOME}/AppManager/app_manager_server.py"
    start_cmd = "#{PYTHON27} #{app_manager_script}"
    stop_cmd = "#{PYTHON27} #{APPSCALE_HOME}/scripts/stop_service.py " +
          "#{app_manager_script} #{PYTHON27}"
    port = [AppManagerClient::SERVER_PORT]
    MonitInterface.start(:appmanagerserver, start_cmd, stop_cmd, port, env_vars)
  end

  # Starts the Hermes service on this node.
  def start_hermes()
    @state = "Starting Hermes"
    Djinn.log_info("Starting Hermes service.")
    HermesService.start()
    Djinn.log_info("Done starting Hermes service.")
  end

  # Starts the groomer service on this node. The groomer cleans the datastore of deleted
  # items and removes old logs.
  def start_groomer_service()
    @state = "Starting Groomer Service"
    Djinn.log_info("Starting groomer service.")
    GroomerService.start()
    Djinn.log_info("Done starting groomer service.")
  end

  def start_soap_server()
    db_master_ip = nil
    @nodes.each { |node|
      db_master_ip = node.private_ip if node.is_db_master?
    }
    HelperFunctions.log_and_crash("db master ip was nil") if db_master_ip.nil?

    db_local_ip = my_node.private_ip

    table = @options['table']

    env_vars = {}

    env_vars['APPSCALE_HOME'] = APPSCALE_HOME
    env_vars['MASTER_IP'] = db_master_ip
    env_vars['LOCAL_DB_IP'] = db_local_ip

    if table == "simpledb"
      env_vars['SIMPLEDB_ACCESS_KEY'] = @options['SIMPLEDB_ACCESS_KEY']
      env_vars['SIMPLEDB_SECRET_KEY'] = @options['SIMPLEDB_SECRET_KEY']
    end

    soap_script = "#{APPSCALE_HOME}/AppDB/soap_server.py"
    start_cmd = ["#{PYTHON27} #{soap_script}",
            "-t #{table}"].join(' ')
    stop_cmd = "#{PYTHON27} #{APPSCALE_HOME}/scripts/stop_service.py " +
          "#{soap_script} #{PYTHON27}"
    port = [UserAppClient::SERVER_PORT]

    MonitInterface.start(:uaserver, start_cmd, stop_cmd, port, env_vars)
  end

  def start_datastore_server
    db_master_ip = nil
    my_ip = my_node.public_ip
    verbose = @options['verbose'].downcase == 'true'
    @nodes.each { |node|
      db_master_ip = node.private_ip if node.is_db_master?
    }
    HelperFunctions.log_and_crash("db master ip was nil") if db_master_ip.nil?

    table = @options['table']
    DatastoreServer.start(db_master_ip, my_node.private_ip, table,
      verbose=verbose)
    HAProxy.create_datastore_server_config(my_node.private_ip, DatastoreServer::PROXY_PORT, table)

    # Let's wait for the datastore to be active.
    HelperFunctions.sleep_until_port_is_open(my_node.private_ip, DatastoreServer::PROXY_PORT)
  end

  # Stops the Backup/Recovery service.
  def stop_backup_service()
    BackupRecoveryService.stop()
  end

  # Stops the blobstore server.
  def stop_blob_server
    BlobServer.stop
  end

  # Stops the User/Apps soap server.
  def stop_soap_server
    MonitInterface.stop(:uaserver)
  end

  # Stops the AppManager service
  def stop_app_manager_server
    MonitInterface.stop(:appmanagerserver)
  end

  # Stops the groomer service.
  def stop_groomer_service()
    Djinn.log_info("Stopping groomer service.")
    GroomerService.stop()
    Djinn.log_info("Done stopping groomer service.")
  end

  # Stops the datastore server.
  def stop_datastore_server
    DatastoreServer.stop()
  end

  def is_hybrid_cloud?
    if @options['infrastructure'].nil?
      false
    else
      @options['infrastructure'] == "hybrid"
    end
  end

  def is_cloud?
    !@options['infrastructure'].nil?
  end

  def restore_from_db?
    @options['restore_from_tar'] || @options['restore_from_ebs']
  end

  def spawn_and_setup_appengine()
    # should also make sure the tools are on the vm and the envvars are set

    table = @options['table']

    machines = JSON.load(@options['ips'])
    appengine_info = spawn_appengine(machines)
    Djinn.log_info("Nodes info after starting remotes: #{appengine_info.join(', ')}.")

    @state = "Copying over needed files and starting the AppController on the other VMs"

    keyname = @options['keyname']
    appengine_info = Djinn.convert_location_array_to_class(appengine_info, keyname)
    @state_change_lock.synchronize {
      @nodes.concat(appengine_info)
      @nodes.uniq!
    }
    find_me_in_locations()
    write_database_info()
    update_firewall()

    initialize_nodes_in_parallel(appengine_info)
  end

  def spawn_appengine(machines)
    Djinn.log_debug("Machines requested or available: #{machines.join(', ')}.")
    appengine_info = []

    if is_cloud?
      # In cloud mode we need to spawn the instances, but we should check
      # if the instances have been already spawned: we can do that
      # comparing what we are requested and what we have in @nodes.
      # Note: the tools doesn't include the headnode in machines.
      if @nodes.length < (machines.length + 1)
        @state = "Spawning up #{machines.length} virtual machines"
        roles = machines.map { |node| node['jobs'] }
        disks = machines.map { |node| node['disk'] }

        Djinn.log_info("Starting #{machines.length} machines.")

        imc = InfrastructureManagerClient.new(@@secret)
        begin
          appengine_info = imc.spawn_vms(machines.length, @options, roles, disks)
        rescue FailedNodeException, AppScaleException => exception
          @state = "Couldn't spawn #{machines.length} VMs " +
            "with roles #{roles} because: #{exception.message}"
          HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
        end
        Djinn.log_info("Spawned #{machines.length} virtual machines.")
      else
        Djinn.log_info("Not spawning new instances since we have the requested" +
          " number already.")
      end
    else
      # For cluster mode, we return a nodes structure with the correct
      # values, since we already have the jobs and ips for the layout.
      machines.each { |node|
        appengine_info << {
          'public_ip' => node['ip'],
          'private_ip' => node['ip'],
          'jobs' => node['jobs'],
          'instance_id' => 'i-APPSCALE',
          'disk' => nil
        }
      }
    end

    Djinn.log_debug("Received appengine info: #{appengine_info.join(', ')}.")
    return appengine_info
  end

  def initialize_nodes_in_parallel(node_info)
    threads = []
    node_info.each { |slave|
      threads << Thread.new {
        initialize_node(slave)
      }
    }

    threads.each { |t| t.join }
    Djinn.log_info("Done initializing nodes.")
  end

  def initialize_node(node)
    copy_encryption_keys(node)
    validate_image(node)
    rsync_files(node)
    run_user_commands(node)
    start_appcontroller(node)
  end

  def validate_image(node)
    ip = node.public_ip
    key = node.ssh_key
    HelperFunctions.ensure_image_is_appscale(ip, key)
    HelperFunctions.ensure_version_is_supported(ip, key)
    HelperFunctions.ensure_db_is_supported(ip, @options['table'], key)
  end

  def copy_encryption_keys(dest_node)
    ip = dest_node.private_ip
    Djinn.log_info("Copying SSH keys to node at IP address #{ip}")
    ssh_key = dest_node.ssh_key
    HelperFunctions.sleep_until_port_is_open(ip, SSH_PORT)

    # Get the username to use for ssh (depends on environments).
    user_name = "ubuntu"
    if ["ec2", "euca"].include?(@options['infrastructure'])
      # Add deployment key to remote instance's authorized_keys.
      options = '-o StrictHostkeyChecking=no -o NumberOfPasswordPrompts=0'
      backup_keys = 'sudo cp -p /root/.ssh/authorized_keys ' +
        '/root/.ssh/authorized_keys.old'
      Djinn.log_run("ssh -i #{ssh_key} #{options} 2>&1 #{user_name}@#{ip} " +
        "'#{backup_keys}'")

      merge_keys = 'sudo sed -n ' +
        '"/Please login/d; w/root/.ssh/authorized_keys" ' +
        "~#{user_name}/.ssh/authorized_keys /root/.ssh/authorized_keys.old"
      Djinn.log_run("ssh -i #{ssh_key} #{options} 2>&1 #{user_name}@#{ip} " +
        "'#{merge_keys}'")
    elsif @options['infrastructure'] == "gce"
      # Since GCE v1beta15, SSH keys don't immediately get injected to newly
      # spawned VMs. It takes around 30 seconds, so sleep a bit longer to be
      # sure.
      user_name = "#{@options['gce_user']}"
      Djinn.log_debug("Waiting for SSH keys to get injected to #{ip}.")
      Kernel.sleep(60)
    end

    Kernel.sleep(SMALL_WAIT)

    secret_key_loc = "#{APPSCALE_CONFIG_DIR}/secret.key"
    cert_loc = "#{APPSCALE_CONFIG_DIR}/certs/mycert.pem"
    key_loc = "#{APPSCALE_CONFIG_DIR}/certs/mykey.pem"

    HelperFunctions.scp_file(secret_key_loc, secret_key_loc, ip, ssh_key)
    HelperFunctions.scp_file(cert_loc, cert_loc, ip, ssh_key)
    HelperFunctions.scp_file(key_loc, key_loc, ip, ssh_key)

    cloud_keys_dir = File.expand_path("#{APPSCALE_CONFIG_DIR}/keys/cloud1")
    make_dir = "mkdir -p #{cloud_keys_dir}"

    cloud_private_key = "#{cloud_keys_dir}/mykey.pem"
    cloud_cert = "#{cloud_keys_dir}/mycert.pem"

    HelperFunctions.run_remote_command(ip, make_dir, ssh_key, NO_OUTPUT)
    HelperFunctions.scp_file(ssh_key, ssh_key, ip, ssh_key)
    HelperFunctions.scp_file(cloud_private_key, cloud_private_key, ip, ssh_key)
    HelperFunctions.scp_file(cloud_cert, cloud_cert, ip, ssh_key)

    # Finally, on GCE, we need to copy over the user's credentials, in case
    # nodes need to attach persistent disks.
    return if @options['infrastructure'] != "gce"

    client_secrets = "#{APPSCALE_CONFIG_DIR}/client_secrets.json"
    gce_oauth = "#{APPSCALE_CONFIG_DIR}/oauth2.dat"

    if File.exists?(client_secrets)
      HelperFunctions.scp_file(client_secrets, client_secrets, ip, ssh_key)
    end

    HelperFunctions.scp_file(gce_oauth, gce_oauth, ip, ssh_key)
  end

  def rsync_files(dest_node)
    appdb = "#{APPSCALE_HOME}/AppDB"
    app_manager = "#{APPSCALE_HOME}/AppManager"
    app_task_queue = "#{APPSCALE_HOME}/AppTaskQueue"
    controller = "#{APPSCALE_HOME}/AppController"
    iaas_manager = "#{APPSCALE_HOME}/InfrastructureManager"
    lib = "#{APPSCALE_HOME}/lib"
    loadbalancer = "#{APPSCALE_HOME}/AppDashboard"
    scripts = "#{APPSCALE_HOME}/scripts"
    server = "#{APPSCALE_HOME}/AppServer"
    server_java = "#{APPSCALE_HOME}/AppServer_Java"
    xmpp_receiver = "#{APPSCALE_HOME}/XMPPReceiver"

    ssh_key = dest_node.ssh_key
    ip = dest_node.private_ip
    options = "-e 'ssh -i #{ssh_key}' -arv --filter '- *.pyc'"

    HelperFunctions.shell("rsync #{options} #{controller}/* root@#{ip}:#{controller}")
    HelperFunctions.shell("rsync #{options} #{server}/* root@#{ip}:#{server}")
    HelperFunctions.shell("rsync #{options} #{server_java}/* root@#{ip}:#{server_java}")
    HelperFunctions.shell("rsync #{options} #{loadbalancer}/* root@#{ip}:#{loadbalancer}")
    HelperFunctions.shell("rsync #{options} --exclude='logs/*' #{appdb}/* root@#{ip}:#{appdb}")
    HelperFunctions.shell("rsync #{options} #{app_manager}/* root@#{ip}:#{app_manager}")
    HelperFunctions.shell("rsync #{options} #{iaas_manager}/* root@#{ip}:#{iaas_manager}")
    HelperFunctions.shell("rsync #{options} #{xmpp_receiver}/* root@#{ip}:#{xmpp_receiver}")
    HelperFunctions.shell("rsync #{options} #{lib}/* root@#{ip}:#{lib}")
    HelperFunctions.shell("rsync #{options} #{app_task_queue}/* root@#{ip}:#{app_task_queue}")
    HelperFunctions.shell("rsync #{options} #{scripts}/* root@#{ip}:#{scripts}")
  end

  def setup_config_files()
    @state = "Setting up database configuration files"

    master_ip = []
    slave_ips = []

    # load datastore helper
    # TODO: this should be the class or module
    table = @options['table']
    # require db_file
    begin
      require "#{table}_helper"
    rescue => e
      backtrace = e.backtrace.join("\n")
      HelperFunctions.log_and_crash("Unable to find #{table} helper." +
        " Please verify datastore type: #{e}\n#{backtrace}")
    end

    @nodes.each { |node|
      master_ip = node.private_ip if node.jobs.include?("db_master")
      if !slave_ips.include? node.private_ip
        slave_ips << node.private_ip if node.jobs.include?("db_slave")
      end
    }

    Djinn.log_debug("Master is at #{master_ip}, slaves are at #{slave_ips.join(', ')}")

    my_public = my_node.public_ip
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/my_public_ip", "#{my_public}\n")

    my_private = my_node.private_ip
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/my_private_ip", "#{my_private}\n")

    head_node_ip = get_public_ip(@options['hostname'])
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/head_node_ip", "#{head_node_ip}\n")

    login_ip = get_login.public_ip
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/login_ip", "#{login_ip}\n")

    login_private_ip = get_login.private_ip
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/login_private_ip", "#{login_private_ip}\n")

    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/masters", "#{master_ip}\n")

    if @nodes.length  == 1
      Djinn.log_info("Only saw one machine, therefore my node is " +
        "also a slave node")
      slave_ips = [ my_private ]
    end

    slave_ips_newlined = slave_ips.join("\n")
    HelperFunctions.write_file("#{APPSCALE_CONFIG_DIR}/slaves", "#{slave_ips_newlined}\n")

    # Invoke datastore helper function
    setup_db_config_files(master_ip, slave_ips, Integer(@options['replication']))

    update_hosts_info()

    # use iptables to lock down outside traffic
    # nodes can talk to each other on any port
    # but only the outside world on certain ports
    #`iptables --flush`
    if FIREWALL_IS_ON
      Djinn.log_run("bash #{APPSCALE_HOME}/firewall.conf")
    end
  end


  # Writes a file to the local filesystem that contains the IP addresses of
  # all machines running memcached. AppServers read this file periodically to
  # get an up-to-date list of the nodes running the memcache service, which can
  # change if AppScale scales up or down.
  def write_memcache_locations()
    memcache_ips = []
    @nodes.each { |node|
      memcache_ips << node.private_ip if node.is_memcache?
    }
    memcache_contents = memcache_ips.join("\n")
    # We write the file only if something changed.
    if memcache_contents != @memcache_contents
      memcache_file = "#{APPSCALE_CONFIG_DIR}/memcache_ips"
      HelperFunctions.write_file(memcache_file, memcache_contents)
      @memcache_contents = memcache_contents
      Djinn.log_debug("Updated memcache servers to #{memcache_ips.join(', ')}")
    end
  end


  # Writes a file to the local filesystem that contains the IP address
  # of a machine that runs the AppDashboard. AppServers use this file
  # to know where to send users to log in. Because users have to be able
  # to access this IP address, we use the public IP here instead of the
  # private IP.
  def write_apploadbalancer_location()
    login_file = "#{APPSCALE_CONFIG_DIR}/appdashboard_public_ip"
    login_ip = get_login.public_ip()
    HelperFunctions.write_file(login_file, login_ip)
  end


  # Writes a file to the local filesystem that contains the IP
  # address of the 'nearest' machine running the TaskQueue service.
  # 'Nearest' is defined as being this node's IP if our node runs TQ,
  # or a random node that runs TQ otherwise.
  def find_nearest_taskqueue()
    rabbitmq_ip = nil
    if my_node.is_taskqueue_master? or my_node.is_taskqueue_slave?
      rabbitmq_ip = my_node.private_ip
    end

    if rabbitmq_ip.nil?
      rabbitmq_ips = []
      @nodes.each { |node|
        if node.is_taskqueue_master? or node.is_taskqueue_slave?
          rabbitmq_ips << node.private_ip
        end
      }
      Djinn.log_debug("TaskQueue servers are at #{rabbitmq_ips.join(', ')}")

      # pick one at random
      rabbitmq_ip = rabbitmq_ips.sort_by { rand }[0]
    end

    Djinn.log_debug("AppServers on this node will connect to TaskQueue " +
      "at #{rabbitmq_ip}")
    rabbitmq_file = "#{APPSCALE_CONFIG_DIR}/rabbitmq_ip"
    rabbitmq_contents = rabbitmq_ip
    HelperFunctions.write_file(rabbitmq_file, rabbitmq_contents)
  end

  # Write the location of where SOLR and the search server are located
  # if they are configured.
  def write_search_node_file()
    search_ip = ""
    @nodes.each { |node|
      search_ip = node.private_ip if node.is_search?
      break;
    }
    HelperFunctions.write_file(Search::SEARCH_LOCATION_FILE,  search_ip)
  end

  # Writes a file to the local file system that tells the taskqueue master
  # all nodes which are taskqueue nodes.
  def write_taskqueue_nodes_file()
    taskqueue_ips = []
    @nodes.each { |node|
      taskqueue_ips << node.private_ip if node.is_taskqueue_master? or node.is_taskqueue_slave?
    }
    taskqueue_contents = taskqueue_ips.join("\n")
    HelperFunctions.write_file(TASKQUEUE_FILE,  taskqueue_contents)
  end

  # Updates files on this machine with information about our hostname
  # and a mapping of where other machines are located.
  def update_hosts_info()
    # If we are running in Docker, don't try to set the hostname.
    if system("grep docker /proc/1/cgroup > /dev/null")
      return
    end


    all_nodes = ""
    @nodes.each_with_index { |node, index|
      all_nodes << "#{HelperFunctions.convert_fqdn_to_ip(node.private_ip)} appscale-image#{index}\n"
    }

    new_etc_hosts = <<HOSTS
127.0.0.1 localhost.localdomain localhost
127.0.1.1 localhost
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
#{all_nodes}
HOSTS

    etc_hosts = "/etc/hosts"
    File.open(etc_hosts, "w+") { |file| file.write(new_etc_hosts) }

    etc_hostname = "/etc/hostname"
    my_hostname = "appscale-image#{@my_index}"
    File.open(etc_hostname, "w+") { |file| file.write(my_hostname) }

    Djinn.log_run("/bin/hostname #{my_hostname}")
  end


  # Writes new nginx configuration files for the App Engine applications
  # hosted in this deployment. Callers should invoke this method whenever
  # there is a change in the number of machines hosting App Engine apps.
  def regenerate_nginx_config_files()
    Djinn.log_debug("Regenerating nginx config files for App Engine apps")
    my_public = my_node.public_ip
    my_private = my_node.private_ip
    login_ip = get_login.private_ip

    Djinn.log_debug("@app_info_map is #{@app_info_map.inspect}")
    @apps_loaded.each { |app|
      http_port = @app_info_map[app]['nginx']
      https_port = @app_info_map[app]['nginx_https']
      proxy_port = @app_info_map[app]['haproxy']
      Djinn.log_debug("Regenerating nginx config for app #{app}, on http " +
        "port #{http_port}, https port #{https_port}, and haproxy port " +
        "#{proxy_port}.")

      static_handlers = HelperFunctions.parse_static_data(app)
      Nginx.write_fullproxy_app_config(app, http_port, https_port,
        my_public, my_private, proxy_port, static_handlers, login_ip,
        @app_info_map[app]['language'])
    }
    Djinn.log_debug("Done writing new nginx config files!")
    Nginx.reload()
  end


  def my_node()
    if @my_index.nil?
      find_me_in_locations()
    end

    if @my_index.nil?
      Djinn.log_debug("My index is nil - is nodes nil? #{@nodes.nil?}")
      if @nodes.nil?
        Djinn.log_debug("My nodes is nil also, timing error? race condition?")
      else
        HelperFunctions.log_and_crash("Couldn't find our position in #{@nodes}")
      end
    end

    return @nodes[@my_index]
  end

  # If we are in cloud mode, we should mount any volume containing our
  # local state.
  def mount_persistent_storage()
    if my_node.disk
      imc = InfrastructureManagerClient.new(@@secret)
      begin
        device_name = imc.attach_disk(@options, my_node.disk, my_node.instance_id)
      rescue FailedNodeException
        Djinn.log_warn("Failed to talk to InfrastructureManager while attaching disk")
        # TODO: this logic (and the following) to retry forever is not
        # healhy.
        Kernel.sleep(SMALL_WAIT)
        retry
      end
      loop {
        if File.exists?(device_name)
          Djinn.log_info("Device #{device_name} exists - mounting it.")
          break
        else
          Djinn.log_info("Device #{device_name} does not exist - waiting for " +
            "it to exist.")
          Kernel.sleep(SMALL_WAIT)
        end
      }

      Djinn.log_run("rm -rf #{PERSISTENT_MOUNT_POINT}")
      Djinn.log_run("mkdir #{PERSISTENT_MOUNT_POINT}")
      mount_output = Djinn.log_run("mount -t ext4 #{device_name} " +
        "#{PERSISTENT_MOUNT_POINT} 2>&1")
      if mount_output.empty?
        Djinn.log_info("Mounted persistent disk #{device_name}, without " +
          "needing to format it.")
        Djinn.log_run("mkdir -p #{PERSISTENT_MOUNT_POINT}/apps")

        # Finally, RabbitMQ expects data to be present at /var/lib/rabbitmq.
        # Make sure there is data present there and that it points to our
        # persistent disk.
        if File.exists?("#{PERSISTENT_MOUNT_POINT}/rabbitmq")
          Djinn.log_run("rm -rf /var/lib/rabbitmq")
        else
          Djinn.log_run("mv /var/lib/rabbitmq #{PERSISTENT_MOUNT_POINT}")
        end
        Djinn.log_run("ln -s #{PERSISTENT_MOUNT_POINT}/rabbitmq /var/lib/rabbitmq")
        return
      end

      Djinn.log_info("Formatting persistent disk #{device_name}")
      Djinn.log_run("mkfs.ext4 -F #{device_name}")

      Djinn.log_info("Mounting persistent disk #{device_name}")
      Djinn.log_run("mount -t ext4 #{device_name} #{PERSISTENT_MOUNT_POINT} " +
        "2>&1")
      Djinn.log_run("mkdir -p #{PERSISTENT_MOUNT_POINT}/apps")

      Djinn.log_run("mv /var/lib/rabbitmq #{PERSISTENT_MOUNT_POINT}")
      Djinn.log_run("ln -s #{PERSISTENT_MOUNT_POINT}/rabbitmq /var/lib/rabbitmq")
    end
  end

  # This function performs basic setup ahead of starting the API services.
  def initialize_server()
    if not HAProxy.is_running?
      HAProxy.initialize_config()
      HAProxy.start()
      Djinn.log_info("HAProxy configured and started.")
    else
      Djinn.log_info("HAProxy already configured.")
    end

    if not Nginx.is_running?
      Nginx.initialize_config()
      Nginx.start()
      Djinn.log_info("Nginx configured and started.")
    else
      Djinn.log_info("Nginx already configured and running.")
    end

    # As per trusty's version of haproxy, we need to have a listening
    # socket for the daemon to start: we do use the uaserver to configured
    # a default route.
    configure_uaserver

    # Volume is mounted, let's finish the configuration of static files.
    if my_node.is_login? and not my_node.is_appengine?
      write_app_logrotate()
      Djinn.log_info("Copying logrotate script for centralized app logs")
    end
    configure_db_nginx()
    write_memcache_locations()
    write_apploadbalancer_location()
    find_nearest_taskqueue()
    write_taskqueue_nodes_file()
    write_search_node_file()
    setup_config_files()
  end

  # Sets up logrotate for this node's centralized app logs.
  # This method is called only when the appengine role does not run
  # on the head node.
  def write_app_logrotate()
    template_dir = File.join(File.dirname(__FILE__), "../lib/templates")
    FileUtils.cp("#{template_dir}/#{APPSCALE_APP_LOGROTATE}",
      "#{LOGROTATE_DIR}/appscale-app")
  end

  # Runs any commands provided by the user in their AppScalefile on the given
  # machine.
  #
  # Args:
  # - node: A DjinnJobData that represents the machine where the given commands
  #   should be executed.
  def run_user_commands(node)
    if @options['user_commands'].class == String
      begin
        commands = JSON.load(@options['user_commands'])
      rescue JSON::ParserError
        commands = @options['user_commands']
      end

      if commands.class == String
        commands = [commands]
      end
    else
      commands = []
    end
    Djinn.log_debug("commands are #{commands}, of class #{commands.class.name}")

    if commands.empty?
      Djinn.log_debug("No user-provided commands were given.")
      return
    end

    ip = node.private_ip
    ssh_key = node.ssh_key
    commands.each { |command|
      HelperFunctions.run_remote_command_without_output(ip, command, ssh_key)
    }
  end

  def set_appcontroller_monit()
    Djinn.log_debug("Configuring AppController monit.")
    env = {
      'HOME' => '/root',
      'APPSCALE_HOME' => APPSCALE_HOME,
      'EC2_HOME' => ENV['EC2_HOME'],
      'JAVA_HOME' => ENV['JAVA_HOME']
    }
    start = "/usr/bin/ruby -w /root/appscale/AppController/djinnServer.rb"
    stop = "/usr/sbin/service appscale-controller stop"
    match_cmd = "/usr/bin/ruby -w /root/appscale/AppController/djinnServer.rb"

    # Let's make sure we don't have 2 jobs monitoring the controller.
    FileUtils.rm_rf("/etc/monit/conf.d/controller-17443.cfg")

    begin
      MonitInterface.start(:controller, start, stop, SERVER_PORT, env,
        match_cmd)
    rescue => e
      Djinn.log_warn("Failed to set local AppController monit: retrying.")
      retry
    end
  end

  def start_appcontroller(node)
    ip = node.private_ip

    # Start the AppController on the remote machine.
    remote_cmd = "/usr/sbin/service appscale-controller start"
    tries = RETRIES
    begin
      result = HelperFunctions.run_remote_command(ip, remote_cmd, node.ssh_key, true)
    rescue => except
      backtrace = except.backtrace.join("\n")
      remote_start_msg = "[remote_start] Unforeseen exception when " + \
        "talking to #{ip}: #{except}\nBacktrace: #{backtrace}"
      tries -= 1
      if tries > 0
        Djinn.log_warn(remote_start_msg)
        retry
      else
        @state = remote_start_msg
        HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
      end
    end
    Djinn.log_info("Starting AppController for #{ip} returned #{result}.")

    # If the node is already initialized, it may belong to another
    # deployment: stop the initialization process.
    acc = AppControllerClient.new(ip, @@secret)
    tries = RETRIES
    begin
      if acc.is_done_initializing?
        Djinn.log_warn("The node at #{ip} was already initialized!")
        return
      end
    rescue FailedNodeException => except
      tries -= 1
      if tries > 0
        Djinn.log_debug("AppController at #{ip} not responding yet: retrying.")
        retry
      else
        @state = "Couldn't talk to AppController at #{ip} for #{except.message}."
        HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
      end
    end
    Djinn.log_debug("Sending data to #{ip}.")

    loc_array = Djinn.convert_location_class_to_array(@nodes)
    options = @options.to_a.flatten
    begin
      result = acc.set_parameters(loc_array, options, @app_names)
    rescue FailedNodeException => e
      @state = "Couldn't set parameters on node at #{ip} for #{e.message}."
      HelperFunctions.log_and_crash(@state, WAIT_TO_CRASH)
    end
    Djinn.log_info("Parameters set on node at #{ip} returned #{result}.")
  end

  def start_memcache()
    @state = "Starting up memcache"
    Djinn.log_info("Starting up memcache")
    start_cmd = "/usr/bin/memcached -m 64 -p 11211 -u root"
    stop_cmd = "#{PYTHON27} #{APPSCALE_HOME}/scripts/stop_service.py " +
          "/usr/bin/memcached 11211"
    MonitInterface.start(:memcached, start_cmd, stop_cmd, [11211])
  end

  def stop_memcache()
    MonitInterface.stop(:memcached)
  end

  def start_ejabberd()
    @state = "Starting up XMPP server"
    my_public = my_node.public_ip
    Ejabberd.stop()
    Djinn.log_run("rm -f /var/lib/ejabberd/*")
    Ejabberd.write_auth_script(my_public, get_db_master.private_ip, @@secret)
    Ejabberd.write_config_file(my_public)
    Ejabberd.start()
  end

  def stop_ejabberd()
    Ejabberd.stop()
  end

  # Start the AppDashboard web service which allows users to login,
  # upload and remove apps, and view the status of the AppScale deployment.
  #
  # Args:
  #  login_ip: A string wth the ip of the login node.
  #  uaserver_ip: A string with the ip of the UserAppServer.
  def start_app_dashboard(login_ip, uaserver_ip)
    @state = "Starting AppDashboard"
    Djinn.log_info("Starting AppDashboard")

    Thread.new{
      my_public = my_node.public_ip
      my_private = my_node.private_ip

      AppDashboard.start(login_ip, uaserver_ip, my_public, my_private,
          PERSISTENT_MOUNT_POINT, @@secret)
      APPS_LOCK.synchronize {
        @app_info_map[AppDashboard::APP_NAME] = {
            'nginx' => AppDashboard::LISTEN_PORT,
            'nginx_https' => AppDashboard::LISTEN_SSL_PORT,
            'haproxy' => AppDashboard::PROXY_PORT,
            'appengine' => ["#{my_private}:-1", "#{my_private}:-1",
                            "#{my_private}:-1"],
            'language' => AppDashboard::APP_LANGUAGE
        }
      }

      Djinn.log_info("Starting cron service for #{AppDashboard::APP_NAME}")
      CronHelper.update_cron(login_ip, AppDashboard::LISTEN_PORT,
        AppDashboard::APP_LANGUAGE, AppDashboard::APP_NAME)
    }
  end

  # Stop the AppDashboard web service.
  def stop_app_dashboard()
    Djinn.log_info("Shutting down AppDashboard")
    AppDashboard.stop()
  end

  def start_shadow()
    Djinn.log_info("Starting Shadow role")
  end

  def stop_shadow()
    Djinn.log_info("Stopping Shadow role")
  end

  #
  # Swaps out an application with one that relays an error message to the
  # developer. It will take the application that currently exists in the
  # application folder, deletes it, and places a templated app that prints out the
  # given error message.
  #
  # Args:
  #   app_name: Name of application to construct an error application for
  #   err_msg: A String message that will be displayed as
  #            the reason why we couldn't start their application.
  #   language: The language the application is written in.
  def place_error_app(app_name, err_msg, language)
    Djinn.log_error("Placing error application for #{app_name} because of: #{err_msg}")
    ea = ErrorApp.new(app_name, err_msg)
    ea.generate(language)
  end

  # Examine the list of applications to restart, or the applications that
  # should be running, and respectively restart or start them.
  def restart_appengine()
    @state = "Preparing to restart AppEngine apps if needed."
    Djinn.log_debug(@state)

    # Use a copy of @apps_to_restart here since we delete from it in
    # setup_appengine_application.
    apps = @apps_to_restart
    apps.each { |app_name|
      Djinn.log_info("Got #{app_name} to restart (if applicable).")
      setup_app_dir(app_name, true)

      APPS_LOCK.synchronize {
        if my_node.is_appengine?
          app_manager = AppManagerClient.new(my_node.private_ip)
          # TODO: What happens if the user updates their env vars between app
          # deploys?
          Djinn.log_info("Restarting AppServers hosting old version of #{app_name}.")
          begin
            result = app_manager.restart_app_instances_for_app(app_name,
              @app_info_map[app_name]['language'])
          rescue FailedNodeException
            Djinn.log_warn("Failed to restart app #{app_name}.")
          end
          maybe_reload_taskqueue_worker(app_name)
        end
        @apps_to_restart.delete(app_name)
        Djinn.log_info("Done restarting #{app_name}.")
      }
    }
  end

  # Login nodes will compares the list of applications that should be
  # running according to the UserAppServer with the list we have on the
  # load balancer, and marks the missing apps for start during the next
  # cycle.
  #
  # All nodes will compares the list of AppServers they should be running,
  # with the list of AppServers actually running, and make the necessary
  # adjustments. Effectively only login nodes and appengine nodes will run
  # AppServers (login nodes runs the dashboard).
  def check_running_apps()
    if my_node.is_login?
      APPS_LOCK.synchronize {
        uac = UserAppClient.new(my_node.private_ip, @@secret)
        Djinn.log_debug("Checking applications that should be running.")
        begin
          app_list = uac.get_all_apps()
        rescue FailedNodeException
          Djinn.log_warn("Failed to get app listing: retrying.")
          retry
        end
        Djinn.log_debug("Apps to check: #{app_list}.") if !app_list.empty?
        app_list.each { |app|
          begin
            # If app is not enabled or if we already know of it, we skip it.
            next if @app_names.include?(app)
            next if !uac.is_app_enabled?(app)

            # If we don't have a record for this app, we start it.
            Djinn.log_info("Adding #{app} to running apps.")

            # We query the UserAppServer looking for application data, in
            # particular ports and language.
            result = uac.get_app_data(app)
            app_data = JSON.load(result)
            Djinn.log_debug("#{app} metadata: #{app_data}")

            app_language = app_data['language']
            Djinn.log_info("Restoring app #{app} (language #{app_language})" +
              " with ports #{app_data['hosts']}.")

            @app_info_map[app] = {} if @app_info_map[app].nil?
            @app_info_map[app]['language'] = app_language if app_language
            if app_data['hosts'].values[0]
              if app_data['hosts'].values[0]['http']
                @app_info_map[app]['nginx'] = app_data['hosts'].values[0]['http']
              end
              if app_data['hosts'].values[0]['https']
                @app_info_map[app]['nginx_https'] = app_data['hosts'].values[0]['https']
              end
            end
            @app_names = @app_names + [app]
          rescue FailedNodeEsception
            Djinn.log_warn("Couldn't check if app #{app} exists on #{db_private_ip}")
          end
        }
        @app_names.uniq!

        # And now starts applications.
        @state = "Preparing to run AppEngine apps if needed."

        apps_to_load = @app_names - @apps_loaded - ["none"]
        apps_to_load.each { |app|
          setup_appengine_application(app)
          maybe_start_taskqueue_worker(app)
        }
      }
    end

    # From here on, we check that the running AppServers match the
    # headnode view.  Only one thread talking to the AppManagerServer at a
    # time.
    if AMS_LOCK.locked?
      Djinn.log_debug("Another thread already working with appmanager.")
      return
    end

    to_start = []
    no_appservers = []
    my_apps = []
    to_end = []
    @app_info_map.each { |app, info|
      next if not info['appengine']

      Djinn.log_debug("Checking #{app} with appengine #{info}.")
      info['appengine'].each { |location|
        host, port = location.split(":")
        next if @my_private_ip != host

        if Integer(port) < 0
          to_start << app
          no_appservers << app
        elsif not MonitInterface.is_running?("#{app}-#{port}")
          Djinn.log_debug("Didn't find the AppServer for #{app} at port #{port}.")
          if @last_decision[app]
            if Time.now.to_i - @last_decision[app] > APP_UPLOAD_TIMEOUT * RETRIES
              Djinn.log_warn("AppServer for #{app} at port #{port} is not running.")
              to_end << "#{app}:#{port}"
            end
          end
        else
          my_apps << "#{app}:#{port}"
        end
      }
    }
    # Let's make sure we have the proper list of apps with no currently
    # running AppServers.
    my_apps.each { |appserver|
      app, port = appserver.split(":")
      no_appservers.delete(app)
    }
    Djinn.log_debug("Running AppServers on this node: #{my_apps}.") if !my_apps.empty?

    # Check that all the AppServers running are indeed known to the
    # head node.
    MonitInterface.running_appengines().each { |appengine|
      # Nothing to do if we already account for this AppServer.
      next if my_apps.include?(appengine)

      # If the app needs to be started, but we have an AppServer not
      # accounted for, we don't take action (ie we wait for headnode
      # state to settle).
      app, port = appengine.split(":")
      time_to_delete = true
      if @last_decision[app]
        if Time.now.to_i - @last_decision[app] < APP_UPLOAD_TIMEOUT * RETRIES
          time_to_delete = false
        end
      end
      if to_start.include?(app) and !time_to_delete
        Djinn.log_debug("Ignoring request for #{app} since we have pending AppServers.")
        to_start.delete(app)
        no_appservers.delete(app)
      else
        to_end << appengine
      end
    }
    Djinn.log_debug("First AppServers to start: #{no_appservers}.") if !no_appservers.empty?
    Djinn.log_debug("AppServers to start: #{to_start}.") if !to_start.empty?
    Djinn.log_debug("AppServers to terminate: #{to_end}.") if !to_end.empty?

    # Now we do the talking with the appmanagerserver. Since it may take
    # some time to start/stop apps, we do this in a thread. We do one
    # operation at a time since it is expensive and we want to
    # re-evaluate.
    Thread.new {
      AMS_LOCK.synchronize {
        if !no_appservers[0].nil?
          Djinn.log_info("Starting first AppServer for app: #{no_appservers[0]}.")
          ret = add_appserver_process(no_appservers[0])
          Djinn.log_debug("add_appserver_process returned: #{ret}.")
        elsif !to_start[0].nil?
          Djinn.log_info("Starting AppServer for app: #{to_start[0]}.")
          ret = add_appserver_process(to_start[0])
          Djinn.log_debug("add_appserver_process returned: #{ret}.")
        elsif !to_end[0].nil?
          Djinn.log_info("Terminate the following AppServer: #{to_end[0]}.")
          app, port = to_end[0].split(":")
          ret = remove_appserver_process(app, port)
          Djinn.log_debug("remove_appserver_process returned: #{ret}.")
        end
      }
    }
  end

  # This functions check the language of the application both in what we
  # recorded in the metadata and in app_info_map.
  # Returns:
  #   language: returns python27, java, php or go depending on the
  #       language of the app, or INVALID_REQUEST in case there is a
  #       discrepancy between the language recorded in the project and the
  #       one in the uploaded application.
  def check_app_language(app)
    app_language = ""

    # Let's get the application language as we have in the metadata (this
    # will be the latest from the user).
    uac = UserAppClient.new(my_node.private_ip, @@secret)
    loop {
      begin
        result = uac.get_app_data(app)
        app_data = JSON.load(result)
        Djinn.log_debug("Got application data for #{app}: #{app_data}.")

        # Let's make sure the application is enabled.
        result = uac.enable_app(app)
        Djinn.log_debug("enable_app returned #{result}.")
        app_language = app_data['language']
        break
      rescue FailedNodeException
        # Failed to talk to the UserAppServer: let's try again.
      end
      Djinn.log_info("Waiting for app data to have instance info for app named #{app}")
      Kernel.sleep(SMALL_WAIT)
    }

    # If the language of the application changed, we disable the app since
    # it may cause some datastore corruption. User will have to create a
    # new ID.
    if !@app_info_map[app].nil?
      if @app_info_map[app]['language'] and @app_info_map[app]['language'] != app_language
        Djinn.log_warn("Application #{app} changed language!")
        return INVALID_REQUEST
      end
    end

    return app_language
  end

  # Performs all of the preprocessing needed to start an App Engine application
  # on this node. This method then starts the actual app by calling the AppManager.
  #
  # Args:
  #   app: A String containing the appid for the app to start.
  def setup_appengine_application(app)
    @state = "Setting up AppServers for #{app}"
    Djinn.log_debug("setup_appengine_application: got a new app #{app}.")

    my_public = my_node.public_ip
    my_private = my_node.private_ip

    # Let's create an entry for the application if we don't already have it.
    @app_info_map[app] = {} if @app_info_map[app].nil?
    @app_info_map[app]['language'] = check_app_language(app)
    if @app_info_map[app]['language'] == INVALID_REQUEST
      # We shoulnd't be here at all!
      Djinn.log_error("Failed to get language for #{app}!")
      stop_app(app, @@secret)
      return
    end

    # Use already assigned ports, or otherwise assign new ports to the
    # application.
    if @app_info_map[app]['nginx'].nil?
      @app_info_map[app]['nginx'] = find_lowest_free_port(
        Nginx::START_PORT, Nginx::END_PORT)
    end
    if @app_info_map[app]['nginx_https'].nil?
      @app_info_map[app]['nginx_https'] = find_lowest_free_port(
        Nginx.get_ssl_port_for_app(Nginx::START_PORT),
        Nginx.get_ssl_port_for_app(Nginx::END_PORT))
    end
    if @app_info_map[app]['haproxy'].nil?
      @app_info_map[app]['haproxy'] = find_lowest_free_port(
        HAProxy::START_PORT)
    end
    if @app_info_map[app]['appengine'].nil?
      @app_info_map[app]['appengine'] = []
    end
    if !@app_info_map[app]['nginx'] or
        !@app_info_map[app]['nginx_https'] or
        !@app_info_map[app]['haproxy']
      # Free possibly allocated ports and return an error if we couldn't
      # get all ports.
      @app_info_map[app]['nginx'] = nil
      @app_info_map[app]['nginx_https'] = nil
      @app_info_map[app]['haproxy'] = nil
      Djinn.log_error("Cannot find an available port for application #{app}")
      return
    end
    Djinn.log_debug("setup_appengine_application: info for #{app}: #{@app_info_map[app]}.")

    # Now let's make sure we have the correct version of the app. In the
    # case of a new start we need to ensure we can unpack the tarball, and
    # in the case of a restart, we need to remove the old unpacked source
    # code, and use the new one.
    setup_app_dir(app, true)

    nginx_port = @app_info_map[app]['nginx']
    https_port = @app_info_map[app]['nginx_https']
    proxy_port = @app_info_map[app]['haproxy']

    port_file = "#{APPSCALE_CONFIG_DIR}/port-#{app}.txt"
    if my_node.is_login?
      HelperFunctions.write_file(port_file, "#{@app_info_map[app]['nginx']}")
      Djinn.log_debug("App #{app} will be using nginx port #{nginx_port}, " +
        "https port #{https_port}, and haproxy port #{proxy_port}")

      # There can be quite a few nodes, let's do this in parallel. We also
      # don't care about the results, since the appengine node will work
      # on its own upon reception of the file.
      @nodes.each { |node|
        next if node.private_ip == my_node.private_ip
        Thread.new {
          begin
            HelperFunctions.scp_file(port_file, port_file, node.private_ip,
              node.ssh_key)
          rescue AppScaleSCPException => exception
            Djinn.log_warn("Failed to give nginx port for app #{app} to " +
              "#{node.private_ip}: #{exception.message}")
          end
        }
      }

      # Setup rsyslog to store application logs.
      app_log_config_file = "/etc/rsyslog.d/10-#{app}.conf"
      begin
        existing_app_log_config = File.open(app_log_config_file, 'r').read()
      rescue Errno::ENOENT
        existing_app_log_config = ''
      end
      app_log_template = HelperFunctions.read_file(RSYSLOG_TEMPLATE_LOCATION)
      app_log_config = app_log_template.gsub("{0}", app)
      unless existing_app_log_config == app_log_config
        Djinn.log_info("Installing log configuration for #{app}.")
        HelperFunctions.write_file(app_log_config_file, app_log_config)
        HelperFunctions.shell("service rsyslog restart")
      end
    end

    if my_node.is_shadow?
      CronHelper.update_cron(my_public, nginx_port,
          @app_info_map[app]['language'], app)
      begin
        start_xmpp_for_app(app, nginx_port, @app_info_map[app]['language'])
      rescue FailedNodeException
        Djinn.log_warn("Failed to start xmpp for application #{app}")
      end
    end

    if @app_names.include?("none")
      @apps_loaded = @apps_loaded - ["none"]
      @app_names = @app_names - ["none"]
    end
    @apps_loaded << app
  end


  # Finds the lowest numbered port that is free to serve a new process.
  #
  # Callers should make sure to store the port returned by this process in
  # @app_info_map, preferably within the use of the APPS_LOCK (so that a
  # different caller doesn't get the same value).
  #
  # Args:
  #   starting_port: we look for ports starting from this port.
  #   ending_port:   we look up to this port, if 0, we keep going.
  #   appid:         if ports are used by this app, we ignore them, if
  #                  nil we check all the applications ports.
  #
  # Returns:
  #   A Fixnum corresponding to the port number that a new process can be bound
  #   to.
  def find_lowest_free_port(starting_port, ending_port=0, appid="")
    possibly_free_port = starting_port
    loop {
      # If we have ending_port, we need to check the upper limit too.
      break if ending_port > 0 and possibly_free_port > ending_port

      # Make sure the port is not already allocated to any application.
      # This is important when applications start at the same time since
      # there can be a race condition allocating ports.
      in_use = false
      @app_info_map.each { |app, info|
        # If appid is defined, let's ignore its ports.
        next if app == appid

        # Make sure we have the variables to look into: if we catch an app
        # early on, it may not have them.
        %w(nginx nginx_https haproxy).each{ |key|
          next unless info[key]
          begin
            in_use = true if possibly_free_port == Integer(info[key])
          rescue ArgumentError
            next
          end
        }

        # These ports are allocated on the AppServers nodes.
        if info['appengine']
          info['appengine'].each { |location|
            host, port = location.split(":")
            in_use = true if possibly_free_port == Integer(port)
          }
        end

        break if in_use
      }

      # Check if the port is really available.
      if !in_use
        actually_available = Djinn.log_run("lsof -i:#{possibly_free_port} -sTCP:LISTEN")
        if actually_available.empty?
          Djinn.log_debug("Port #{possibly_free_port} is available for use.")
          return possibly_free_port
        end
      end

      # Let's try the next available port.
      Djinn.log_debug("Port #{possibly_free_port} is in use, so skipping it.")
      possibly_free_port += 1
    }
    return -1
  end


  # Adds or removes AppServers within a node based on the number of requests
  # that each application has received as well as the number of requests that
  # are sitting in haproxy's queue, waiting to be served.
  def scale_appservers_within_nodes
    APPS_LOCK.synchronize {
      @apps_loaded.each { |app_name|
        next if app_name == "none"

        initialize_scaling_info_for_app(app_name)

        # Always get scaling info, as that will send this info to the
        # AppDashboard for users to view.
        case get_scaling_info_for_app(app_name)
        when :scale_up
          Djinn.log_debug("Considering scaling up app #{app_name}.")
          try_to_scale_up(app_name)
        when :scale_down
          Djinn.log_debug("Considering scaling down app #{app_name}.")
          try_to_scale_down(app_name)
        else
          Djinn.log_debug("Not scaling app #{app_name} up or down right now.")
        end
      }
    }
  end


  # Sets up information about the request rate and number of requests in
  # haproxy's queue for the given application.
  #
  # Args:
  #   app_name: The name of the application to set up scaling info
  #   force: A boolean value that indicates if we should reset the scaling
  #     info even in the presence of existing scaling info.
  def initialize_scaling_info_for_app(app_name, force=false)
    return if @initialized_apps[app_name] and !force

    @current_req_rate[app_name] = 0
    @total_req_rate[app_name] = 0
    @last_sampling_time[app_name] = Time.now.to_i

    if !@last_decision.has_key?(app_name)
      @last_decision[app_name] = 0
    end

    @initialized_apps[app_name] = true
  end


  # Retrieves HAProxy stats for the given app.
  #
  # Args:
  #   app_name: The name of the app to get HAProxy stats for.
  # Returns:
  #   The total requests for the app, the requests enqueued and the
  #    timestamp of stat collection.
  def get_haproxy_stats(app_name)
    Djinn.log_debug("Getting scaling info for application #{app_name}")

    total_requests_seen = 0
    total_req_in_queue = 0
    time_requests_were_seen = 0

    # Retrieve total and enqueued requests for the given app.
    monitoring_info = Djinn.log_run("echo \"show info;show stat\" | " +
      "socat stdio unix-connect:/etc/haproxy/stats | grep #{app_name}")
    Djinn.log_debug("HAProxy raw stats: #{monitoring_info}")

    if monitoring_info.empty?
      Djinn.log_warn("Didn't see any monitoring info - #{app_name} may not " +
        "be running.")
      return :no_change, :no_change, :no_backend
    end

    monitoring_info.each_line { |line|
      parsed_info = line.split(',')
      if parsed_info.length < TOTAL_REQUEST_RATE_INDEX  # no request info here
        next
      end

      service_name = parsed_info[SERVICE_NAME_INDEX]

      if service_name == "FRONTEND"
        total_requests_seen = parsed_info[TOTAL_REQUEST_RATE_INDEX].to_i
        time_requests_were_seen = Time.now.to_i
        Djinn.log_debug("#{app_name} #{service_name} Requests Seen " +
          "#{total_requests_seen}")
      end

      if service_name == "BACKEND"
        total_req_in_queue = parsed_info[REQ_IN_QUEUE_INDEX].to_i
        Djinn.log_debug("#{app_name} #{service_name} Queued Currently " +
          "#{total_req_in_queue}")
      end
    }

    return total_requests_seen, total_req_in_queue, time_requests_were_seen
  end

  # Queries haproxy to see how many requests are queued for a given application
  # and how many requests are served at a given time. Based on this information,
  # this method reports whether or not AppServers should be added, removed, or
  # if no changes are needed.
  def get_scaling_info_for_app(app_name, update_dashboard=true)
    total_requests_seen = 0
    total_req_in_queue = 0
    time_requests_were_seen = 0

    # Let's make sure we have the minimum number of AppServers running.
    Djinn.log_debug("Evaluating app #{app_name} for scaling.")
    if @app_info_map[app_name]['appengine'].length < @num_appengines
       Djinn.log_info("App #{app_name} doesn't have enough AppServers.")
       @last_decision[app_name] = 0
      return :scale_up
    end

    # We need the haproxy stats to decide upon what to do.
    total_requests_seen, total_req_in_queue, time_requests_were_seen = get_haproxy_stats(app_name)

    if time_requests_were_seen == :no_backend
      Djinn.log_warn("Didn't see any request data - not sure whether to scale up or down.")
      return :no_change
    end

    update_request_info(app_name, total_requests_seen, time_requests_were_seen,
      total_req_in_queue, update_dashboard)

    if total_req_in_queue.zero?
      Djinn.log_debug("No requests are enqueued for app #{app_name} - " +
        "advising that we scale down within this machine.")
      return :scale_down
    end

    if total_req_in_queue > SCALEUP_QUEUE_SIZE_THRESHOLD
      Djinn.log_debug("#{total_req_in_queue} requests are enqueued for app " +
        "#{app_name} - advising that we scale up within this machine.")
      return :scale_up
    end

    Djinn.log_debug("#{total_req_in_queue} requests are enqueued for app " +
      "#{app_name} - advising that don't scale either way on this machine.")
    return :no_change
  end


  # Updates internal state about the number of requests seen for the given App
  # Engine app, as well as how many requests are currently enqueued for it.
  # Some of this information is also sent to the AppDashboard for viewing by
  # users.
  #
  # Args:
  #   app_name: A String that indicates the name this Google App Engine
  #     application is registered as.
  #   total_requests_seen: An Integer that indicates how many requests haproxy
  #     has received for the given application since we reloaded it (which
  #     occurs when we start the app or add/remove AppServers).
  #   time_requests_were_seen: An Integer that represents the epoch time when we
  #     got request info from haproxy.
  #   total_req_in_queue: An Integer that represents the current number of
  #     requests waiting to be served.
  #   update_dashboard: A boolean to indicate if we send the information
  #     to the dashboard.
  def update_request_info(app_name, total_requests_seen,
    time_requests_were_seen, total_req_in_queue,  update_dashboard)
    Djinn.log_debug("Time now is #{time_requests_were_seen}, last " +
      "time was #{@last_sampling_time[app_name]}")
    Djinn.log_debug("Total requests seen now is #{total_requests_seen}, last " +
      "time was #{@total_req_rate[app_name]}")
    Djinn.log_debug("Requests currently in the queue #{total_req_in_queue}")
    requests_since_last_sampling = total_requests_seen - @total_req_rate[app_name]
    time_since_last_sampling = time_requests_were_seen - @last_sampling_time[app_name]
    if time_since_last_sampling.zero?
      time_since_last_sampling = 1
    end

    average_request_rate = Float(requests_since_last_sampling) / Float(time_since_last_sampling)
    if average_request_rate < 0
      Djinn.log_info("Saw negative request rate for app #{app_name}, so " +
        "resetting our haproxy stats for this app.")
      initialize_scaling_info_for_app(app_name, force=true)
      return
    end

    if update_dashboard
      send_request_info_to_dashboard(app_name, time_requests_were_seen,
        average_request_rate)
    end

    Djinn.log_debug("Total requests will be set to #{total_requests_seen} " +
      "for app #{app_name}, with last sampling time #{time_requests_were_seen}")
    @current_req_rate[app_name] = total_req_in_queue
    @total_req_rate[app_name] = total_requests_seen
    @last_sampling_time[app_name] = time_requests_were_seen
  end


  def try_to_scale_up(app_name)
    if @app_info_map[app_name].nil? or @app_info_map[app_name]['appengine'].nil?
      Djinn.log_info("Not scaling up app #{app_name}, since we aren't " +
        "hosting it anymore.")
      return
    end

    # We scale only if the designed time is passed.
    if Time.now.to_i - @last_decision[app_name] < SCALEUP_THRESHOLD * DUTY_CYCLE
      Djinn.log_debug("Not enough time as passed to scale up app #{app_name}")
      return
    end

    # All the available appengine servers.
    appservers_running = get_all_appengine_nodes()

    # Select an appengine machine if it has enough resources to support
    # another AppServer for this app.
    available_hosts = {}
    appservers_running.each { |host|
      @all_stats.each { |node|
        if node['private_ip'] == host
          # The host needs to have normalized average load less than
          # MAX_LOAD_AVG, current CPU usage less than 90% and enough
          # memory to run an AppServer (and some safe extra).
          if Float(node['free_memory']) > Integer(@options['max_memory']) + SAFE_MEM and
              Float(node['cpu']) < MAX_CPU_FOR_APPSERVERS and
              Float(node['load']) / Float(node['num_cpu']) < MAX_LOAD_AVG
            available_hosts[host] = (Float(node['load']) / Float(node['num_cpu']))
          else
            Djinn.log_debug("#{host} is too busy: not using it to scale #{app_name}")
          end
          break         # We found the host's statistics.
        end
      }
    }

    # Now let's prefer hosts that are not already running a copy of this
    # app. Otherwise we select the host with the lowest load.
    if available_hosts.keys[0] != nil
      appserver_to_use = []
      appengine_running = []

      if @app_info_map[app_name]['appengine']
        @app_info_map[app_name]['appengine'].each { |location|
          host, port = location.split(":")
          appengine_running << host
        }
        Djinn.log_debug("These hosts are running #{app_name}: #{appengine_running}.")
        available_hosts.each { |host, load|
          if !appengine_running.include?(host)
            Djinn.log_debug("Prioritizing #{host} to run #{app_name} " +
                "since it has no running AppServers for it.")
            appserver_to_use = host
            break
          end
        }
      end

      # If we didn't find any unused host, we will pick the least loaded.
      if appserver_to_use.empty?
        appserver_to_use = available_hosts.keys[0]
        available_hosts.each { |host, load|
          appserver_to_use = host if available_hosts[appserver_to_use] > load
        }
      end
      Djinn.log_info("Adding a new AppServer on #{appserver_to_use} for #{app_name}")
      @app_info_map[app_name]['appengine'] << "#{appserver_to_use}:-1"
      @last_decision[app_name] = Time.now.to_i
    else
      Djinn.log_info("No AppServer available to scale #{app_name}")
      # If we're this far, no room is available for AppServers, so try to add a
      # new node instead.
      ZKInterface.request_scale_up_for_app(app_name, my_node.private_ip)
    end
  end


  def try_to_scale_down(app_name)
    if @app_info_map[app_name].nil? or @app_info_map[app_name]['appengine'].nil?
      Djinn.log_debug("Not scaling down app #{app_name}, since we aren't " +
        "hosting it anymore.")
      return
    end

    # We scale only if the designed time is passed.
    if Time.now.to_i - @last_decision[app_name] < SCALEDOWN_THRESHOLD * DUTY_CYCLE
      Djinn.log_debug("Not enough time as passed to scale down app #{app_name}")
      return
    end

    # See how many AppServers are running on each machine. We cannot scale
    # if we already are at the requested minimum @num_appengines.
    if @app_info_map[app_name]['appengine'].length <= @num_appengines
      Djinn.log_debug("We are already at the minimum number of AppServers for " +
        "#{app_name}: requesting to remove node.")

      # If we're this far, nobody can scale down, so try to remove a node instead.
      ZKInterface.request_scale_down_for_app(app_name, my_node.private_ip)
      return
    end

    # We pick a randon appengine that run the application.  Smarter
    # algorithms could be implemented, but without clear directives (ie
    # decide on cpu, or memory, or number of CPU available, or avg load
    # etc...) any static strategy is flawed, so we go for simplicity.
    scapegoat = @app_info_map[app_name]['appengine'].sample()
    appserver_to_use, port = scapegoat.split(":")
    Djinn.log_info("Removing an AppServer from #{appserver_to_use} for #{app_name}")

    @app_info_map[app_name]['appengine'].delete("#{appserver_to_use}:#{port}")
    @last_decision[app_name] = Time.now.to_i
  end

  # This function unpacks an application tarball if needed. A removal of
  # the old application code can be forced with a parameter.
  #
  # Args:
  #   app       : the application name to setup
  #   remove_old: boolean to force a re-setup of the app from the tarball
  def setup_app_dir(app, remove_old=false)
    app_dir = "#{HelperFunctions.get_app_path(app)}/app"
    app_path = "#{PERSISTENT_MOUNT_POINT}/apps/#{app}.tar.gz"
    error_msg = ""

    if remove_old
      Djinn.log_info("Removing old application version for app: #{app}.")
      if !my_node.is_login?
        FileUtils.rm_rf(app_path)
      else
        # Force the login node to refresh the applicaiton directory.
        FileUtils.rm_rf(app_dir)
      end
    end

    # Let's make sure we have a copy of the tarball of the application. If
    # not, we will get the latest version from another node.
    if !File.exists?(app_path)
      FileUtils.rm_rf(app_dir)
    end

    if !File.directory?(app_dir)
      Djinn.log_info("App untar directory created from scratch.")
      FileUtils.mkdir_p(app_dir)

      # Let's make sure we have a copy of the application locally.
      if copy_app_to_local(app)
        # Let's make sure their app has an app.yaml or appengine-web.xml in it,
        # since the following code assumes it is present. If it is not there
        # (which can happen if the scp fails on a large app), throw up a dummy
        # app.
        if !HelperFunctions.app_has_config_file?(app_path)
          error_msg = "ERROR: No app.yaml or appengine-web.xml for app: #{app}."
        else
          # Application is good: let's set it up.
          HelperFunctions.setup_app(app)
        end
      else
        # If we couldn't get a copy of the application, place a dummy error
        # application to inform the user we had issues.
        error_msg = "ERROR: Failed to copy app: #{app}."
      end
    end

    if !error_msg.empty?
      # Something went wrong: place the error applcation instead.
      place_error_app(app, error_msg, @app_info_map[app]['language'])
      @app_info_map[app]['language'] = "python27"
    end
  end


  # Starts a new AppServer for the given application.
  #
  # Args:
  #   app_id: A String naming the application that an additional instance will
  #     be added for.
  #   secret: A String that is used to authenticate the caller.
  #
  # Returns:
  #   A Boolean to indicate if the appserver was successfully started.
  def add_appserver_process(app)
    Djinn.log_info("Received request to add an AppServer for #{app}.")

    if @app_info_map[app].nil? or @app_info_map[app]['language'].nil?
      Djinn.log_warn "add_appserver_process: #{app} is unknown."
      return false
    end

    APPS_LOCK.synchronize {
      # Make sure we have the application code.
      setup_app_dir(app)
    }

    app_language = @app_info_map[app]['language']

    # We use the ports as assigned by the head node.
    nginx_port = @app_info_map[app]['nginx']
    https_port = @app_info_map[app]['nginx_https']
    proxy_port = @app_info_map[app]['haproxy']

    # Wait for the head node to be setup for this app.
    port_file = "#{APPSCALE_CONFIG_DIR}/port-#{app}.txt"
    if !File.exists?(port_file)
      Djinn.log_info("Waiting for port file for app #{app}.")
      return false
    end

    # TODO: What happens if the user updates their env vars between app
    # deploys?

    appengine_port = find_lowest_free_port(STARTING_APPENGINE_PORT)
    if appengine_port < 0
      Djinn.log_error("Failed to get port for application #{app} on " +
        "#{@my_private_ip}")
      return false
    end
    Djinn.log_info("Starting #{app_language} app #{app} on " +
      "#{@my_private_ip}:#{appengine_port}")

    xmpp_ip = get_login.public_ip

    app_manager = AppManagerClient.new(my_node.private_ip)
    begin
      pid = app_manager.start_app(app, appengine_port,
        get_load_balancer_ip(), app_language, xmpp_ip,
        HelperFunctions.get_app_env_vars(app),
        Integer(@options['max_memory']), get_login.private_ip)
    rescue FailedNodeException, ArgumentError => error
      Djinn.log_warn("#{error.class} encountered while starting #{app} "\
        "with AppManager: #{error.message}")
      pid = -1
    end
    if pid < 0
      # Something may have gone wrong: inform the user and move on.
      Djinn.log_warn("Something went wrong starting AppServer for" +
        " #{app}: check logs and running processes as duplicate" +
        " ports may have been allocated.")
    end
    maybe_start_taskqueue_worker(app)
    Djinn.log_info("Done adding AppServer for #{app}.")
    return true
  end


  # Terminates a specific AppServer (determined by the listening port)
  # that hosts the specified App Engine app.
  #
  # Args:
  #   app_id: A String naming the application that a process will be removed
  #     from.
  #   port: A Fixnum that names the port of the AppServer to remove.
  #   secret: A String that is used to authenticate the caller.
  # Returns:
  #   A Boolean indicating the success of the operation.
  def remove_appserver_process(app_id, port)
    @state = "Stopping an AppServer to free unused resources"
    Djinn.log_debug("Deleting AppServer instance to free up unused resources")

    uac = UserAppClient.new(my_node.private_ip, @@secret)
    app_manager = AppManagerClient.new(my_node.private_ip)

    begin
      app_is_enabled = uac.is_app_enabled?(app_id)
    rescue FailedNodeException
      Djinn.log_warn("Failed to talk to the UserAppServer about " +
        "application #{app_id}")
      return false
    end
    Djinn.log_debug("is app #{app_id} enabled? #{app_is_enabled}")
    if app_is_enabled == "false"
      return false
    end

    begin
      result = app_manager.stop_app_instance(app_id, port)
    rescue FailedNodeException
      Djinn.log_error("Unable to talk to the UserAppServer " +
        "stop instance on port #{port} for application #{app_id}.")
      result = false
    end
    if !result
      Djinn.log_error("Unable to stop instance on port #{port} " +
        "application #{app_id}")
    end

    # Tell the AppDashboard that the AppServer has been killed.
    delete_instance_from_dashboard(app, "#{my_node.private_ip}:#{port}")

    return true
  end


  # Tells the AppDashboard how many requests were served for the named
  # application at the given time, so that it can display this info to users
  # graphically.
  #
  # Args:
  #   app_id: A String that indicates which application id we are storing
  #     request info for.
  #   timestamp: An Integer that indicates the epoch time when we measured the
  #     request rate for the given application.
  #   request_rate: An Integer that indicates how many requests were served for
  #     the given application in the last second since we queried it.
  # Returns:
  #   true if the request info was successfully sent, and false otherwise.
  def send_request_info_to_dashboard(app_id, timestamp, request_rate)
    Djinn.log_debug("Sending a log with request rate #{app_id}, timestamp " +
      "#{timestamp}, request rate #{request_rate}")
    encoded_request_info = JSON.dump({
      'timestamp' => timestamp,
      'request_rate' => request_rate
    })

    begin
      url = URI.parse("https://#{get_login.public_ip}:" +
        "#{AppDashboard::LISTEN_SSL_PORT}/apps/json/#{app_id}")
      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      response = http.post(url.path, encoded_request_info,
        {'Content-Type'=>'application/json'})
      return true
    rescue OpenSSL::SSL::SSLError, NotImplementedError, Errno::EPIPE,
      Errno::ECONNRESET => e
      backtrace = e.backtrace.join("\n")
      Djinn.log_warn("Error sending logs: #{e.message}\n#{backtrace}")
      retry
    rescue
      # Don't crash the AppController because we weren't able to send over
      # the request info - just inform the caller that we couldn't send it.
      Djinn.log_info("Couldn't send request info for app #{app_id} to #{url}")
      return false
    end
  end


  def scale_appservers_across_nodes()
    return if !my_node.is_login?
    # TODO: Do we need to get the apps lock here?
    Djinn.log_debug("Seeing if we need to spawn new AppServer nodes")

    nodes_needed = []
    all_scaling_requests = {}
    @apps_loaded.each { |appid|
      begin
        scaling_requests = ZKInterface.get_scaling_requests_for_app(appid)
        all_scaling_requests[appid] = scaling_requests
        ZKInterface.clear_scaling_requests_for_app(appid)
      rescue FailedZooKeeperOperationException => e
        Djinn.log_warn("(scale_appservers_across_nodes) issues talking " +
          "to zookeeper with #{e.message}.")
        next
      end
      scale_up_requests = scaling_requests.select { |item| item == "scale_up" }
      num_of_scale_up_requests = scale_up_requests.length

      # Spawn an additional node if the login node requests it.
      if num_of_scale_up_requests > 0
        Djinn.log_debug("Login node is requesting more AppServers for app " +
          "#{appid}, so adding a node.")
        nodes_needed << ["memcache", "taskqueue_slave", "appengine"]
      end
    }

    if nodes_needed.empty?
      Djinn.log_debug("Not adding any new AppServers at this time. Checking " +
        "to see if we need to scale down.")
      return examine_scale_down_requests(all_scaling_requests)
    end

    if Time.now.to_i - @last_scaling_time < (SCALEUP_THRESHOLD *
            SCALE_TIME_MULTIPLIER * DUTY_CYCLE)
      Djinn.log_info("Not scaling up right now, as we recently scaled " +
        "up or down.")
      return 0
    end

    Djinn.log_info("Need to spawn #{nodes_needed.length} new AppServers.")
    added_nodes = start_new_roles_on_nodes(nodes_needed,
      @options['instance_type'], @@secret)

    if added_nodes != "OK"
      Djinn.log_error("Was not able to add #{nodes_needed.length} new nodes" +
        " because: #{added_nodes}")
      return 0
    end

    regenerate_nginx_config_files()
    @last_scaling_time = Time.now.to_i
    return nodes_needed.length
  end


  # Searches through the requests to scale up and down each application in this
  # AppScale deployment, and determines if machines need to be terminated due
  # to excess capacity.
  #
  # Args:
  #   all_scaling_votes: A Hash that maps each appid (a String) to the votes
  #     received to scale the app up or down (an Array of Strings).
  # Returns:
  #   An Integer that indicates how many nodes were added to this AppScale
  #   deployment. A negative number indicates that that many nodes were
  #   removed from this AppScale deployment.
  def examine_scale_down_requests(all_scaling_votes)
    # First, only scale down in cloud environments.
    if !is_cloud?
      Djinn.log_debug("Not scaling down VMs, because we aren't in a cloud.")
      return 0
    end

    if @nodes.length <= Integer(@options['min_images']) or @nodes.length <= 1
      Djinn.log_debug("Not scaling down VMs right now, as we are at the " +
        "minimum number of nodes the user wants to use.")
      return 0
    end

    # Second, only consider scaling down if nobody wants to scale up.
    @apps_loaded.each { |appid|
      scale_ups = all_scaling_votes[appid].select { |vote| vote == "scale_up" }
      if scale_ups.length > 0
        Djinn.log_debug("Not scaling down VMs, because app #{appid} wants to scale" +
          " up.")
        return 0
      end
    }

    # Third, only consider scaling down if we get two votes to scale down on
    # the same app, just like we do for scaling up.
    scale_down_threshold_reached = false
    @apps_loaded.each { |appid|
      scale_downs = all_scaling_votes[appid].select { |vote| vote == "scale_down" }
      if scale_downs.length > 0
        Djinn.log_info("Got a vote to scale down app #{appid}, so " +
          "considering removing VMs.")
        scale_down_threshold_reached = true
      end
    }

    if !scale_down_threshold_reached
      Djinn.log_debug("Not scaling down VMs right now, as not enough nodes have " +
        "requested it.")
      return 0
    end

    # Also, don't scale down if we just scaled up or down.
    if Time.now.to_i - @last_scaling_time < (SCALEDOWN_THRESHOLD *
            SCALE_TIME_MULTIPLIER * DUTY_CYCLE)
      Djinn.log_info("Not scaling down VMs right now, as we recently scaled " +
        "up or down.")
      return 0
    end

    # Finally, find a node to remove and remove it.
    node_to_remove = nil
    @nodes.each { |node|
      if node.jobs == ["memcache", "taskqueue_slave", "appengine"]
        Djinn.log_info("Removing node #{node}")
        node_to_remove = node
        break
      end
    }

    if node_to_remove.nil?
      Djinn.log_warn("Tried to scale down but couldn't find a node to remove.")
      return 0
    end

    remove_app_hosting_data_for_node(node_to_remove.public_ip)
    remove_node_from_local_and_zookeeper(node_to_remove.public_ip)

    @app_info_map.each { |app_id, info|
      if info['appengine'].nil?
        next
      end

      info['appengine'].each { |location|
        host, port = location.split(":")
        if host == node_to_remove.private_ip
          remove_appserver_from_haproxy(app_id, host, port, @@secret)
          delete_instance_from_dashboard(app_id, "#{host}:#{port}")
        end
      }
    }

    imc = InfrastructureManagerClient.new(@@secret)
    begin
      imc.terminate_instances(@options, node_to_remove.instance_id)
    rescue FailedNodeException
      Djinn.log_warn("Failed to call terminate_instances")
    end
    regenerate_nginx_config_files()
    @last_scaling_time = Time.now.to_i
    return -1
  end


  def stop_appengine()
    Djinn.log_info("Shutting down AppEngine")

    erase_app_instance_info()
    Nginx.reload()

    APPS_LOCK.synchronize {
      @app_names = []
      @apps_loaded = []
    }
  end

  # Returns true on success, false otherwise
  def copy_app_to_local(appname)
    app_path = "#{PERSISTENT_MOUNT_POINT}/apps/#{appname}.tar.gz"

    if File.exists?(app_path)
      Djinn.log_debug("I already have a copy of app #{appname} - won't grab it remotely")
      return true
    else
      Djinn.log_debug("I don't have a copy of app #{appname} - will grab it remotely")
    end

    nodes_with_app = []
    retries_left = 10
    loop {
      nodes_with_app = ZKInterface.get_app_hosters(appname, @options['keyname'])
      break if !nodes_with_app.empty?
      Djinn.log_info("[#{retries_left} retries left] Waiting for a node to " +
        "have a copy of app #{appname}")
      Kernel.sleep(SMALL_WAIT)
      retries_left -=1
      if retries_left.zero?
        Djinn.log_warn("Nobody appears to be hosting app #{appname}")
        return false
      end
    }

    # Try 3 times on each node known to have this application
    nodes_with_app.each { |node|
      ssh_key = node.ssh_key
      ip = node.private_ip
      tries = 3
      loop {
        Djinn.log_debug("Trying #{ip}:#{app_path} for the application.")
        Djinn.log_run("scp -o StrictHostkeyChecking=no -i #{ssh_key} #{ip}:#{app_path} #{app_path}")
        if File.exists?(app_path)
          done_uploading(appname, app_path, @@secret)
          Djinn.log_debug("Got a copy of #{appname} from #{ip}.")
          return true
        end
        Djinn.log_warn("Unable to get the application from #{ip}:#{app_path}! scp failed.")
        if tries > 0
          Djinn.log_debug("Trying again in few seconds.")
          tries = tries - 1
          Kernel.sleep(SMALL_WAIT)
        else
          Djinn.log_warn("Giving up on node #{ip} for the application.")
          break
        end
      }
    }
    Djinn.log_error("Unable to get the application from any node.")
    return false
  end

  # This function creates the xmpp account for 'app', as app@login_ip.
  def start_xmpp_for_app(app, port, app_language)
    watch_name = "xmpp-#{app}"

    # If we have it already running, nothing to do
    if MonitInterface.is_running?(watch_name)
      Djinn.log_debug("xmpp already running for application #{app}")
      return
    end

    # We don't need to check for FailedNodeException here since we catch
    # it at a higher level.
    login_ip = get_login.public_ip
    uac = UserAppClient.new(my_node.private_ip, @@secret)
    xmpp_user = "#{app}@#{login_ip}"
    xmpp_pass = HelperFunctions.encrypt_password(xmpp_user, @@secret)
    result = uac.commit_new_user(xmpp_user, xmpp_pass, "app")
    Djinn.log_debug("User creation returned: #{result}")
    if result.include?('Error: user already exists')
      # We need to update the password of the channel XMPP account for
      # authorization.
      result = uac.change_password(xmpp_user, xmpp_pass)
      Djinn.log_debug("Change password returned: #{result}")
    end

    Djinn.log_debug("Created user [#{xmpp_user}] with password [#{@@secret}] and hashed password [#{xmpp_pass}]")

    if Ejabberd.does_app_need_receive?(app, app_language)
      start_cmd = "#{PYTHON27} #{APPSCALE_HOME}/XMPPReceiver/xmpp_receiver.py #{app} #{login_ip} #{@@secret}"
      stop_cmd = "#{PYTHON27} #{APPSCALE_HOME}/scripts/stop_service.py " +
        "xmpp_receiver.py #{app}"
      MonitInterface.start(watch_name, start_cmd, stop_cmd, 9999)
      Djinn.log_debug("App #{app} does need xmpp receive functionality")
    else
      Djinn.log_debug("App #{app} does not need xmpp receive functionality")
    end
  end

  # Stop the xmpp receiver for an application.
  #
  # Args:
  #   app: The application ID whose XMPPReceiver we should shut down.
  def stop_xmpp_for_app(app)
    Djinn.log_info("Shutting down xmpp receiver for app: #{app}")
    MonitInterface.stop("xmpp-#{app}")
    Djinn.log_info("Done shutting down xmpp receiver for app: #{app}")
  end

  def start_open()
    return
  end

  def stop_open()
    return
  end

  # Gathers App Controller and System Manager stats for this node.
  #
  # Args:
  #   secret: The secret of this deployment.
  # Returns:
  #   A hash in string format containing system and platform stats for this
  #     node.
  def get_all_stats(secret)
    if !valid_secret?(secret)
      return BAD_SECRET_MSG
    end

    # Get default AppController stats.
    controller_stats = get_stats(secret)
    Djinn.log_debug("Controller stats: #{controller_stats}")

    # Get stats from SystemManager.
    imc = InfrastructureManagerClient.new(secret)
    system_stats = imc.get_system_stats()
    Djinn.log_debug("System stats: #{system_stats}")

    # Combine all useful stats and return.
    all_stats = system_stats
    if my_node.is_login?
      all_stats["apps"] = {}
      if !app_info_map.nil?
        controller_stats["apps"].each { |app_name, enabled|
          # Get HAProxy requests.
          Djinn.log_debug("Getting HAProxy stats for app: #{app_name}")
          if app_name != "none"
            total_reqs, reqs_enqueued, collection_time = get_haproxy_stats(app_name)
            # Create the apps hash with useful information containing HAProxy stats.
            begin
              if collection_time == :no_backend
                appservers = 0
                total_reqs = 0
                reqs_enqueued = 0
              else
                appservers = @app_info_map[app_name]["appengine"].length
              end

              all_stats["apps"][app_name] = {
                "language" => @app_info_map[app_name]["language"].tr('^A-Za-z', ''),
                "appservers" => appservers,
                "http" => @app_info_map[app_name]["nginx"],
                "https" => @app_info_map[app_name]["nginx_https"],
                "total_reqs" => total_reqs,
                "reqs_enqueued" => reqs_enqueued
              }
            rescue => exception
              backtrace = exception.backtrace.join("\n")
              message = "Unforseen exception: #{exception} \nBacktrace: #{backtrace}"
              Djinn.log_warn("Unable to get application stats: #{message}")
            end
          end
        }
      end
    end
    all_stats["public_ip"] = controller_stats["ip"]
    all_stats["private_ip"] = controller_stats["private_ip"]
    all_stats["roles"] = controller_stats["roles"]
    Djinn.log_debug("All stats: #{all_stats}")

    return JSON.dump(all_stats)
  end

end
