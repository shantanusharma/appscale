# The intervals for updating local stats (in milliseconds)
UPDATE_NODE_STATS_INTERVAL = 15*1000
UPDATE_PROCESSES_STATS_INTERVAL = 65*1000
UPDATE_PROXIES_STATS_INTERVAL = 35*1000

# The intervals for updating cluster stats (in milliseconds)
UPDATE_CLUSTER_NODES_STATS_INTERVAL = 15*1000
UPDATE_CLUSTER_PROCESSES_STATS_INTERVAL = 65*1000
UPDATE_CLUSTER_PROXIES_STATS_INTERVAL = 35*1000

# The intervals for updating local stats
NODE_STATS_CACHE_SIZE = 5
PROCESSES_STATS_CACHE_SIZE = 5
PROXIES_STATS_CACHE_SIZE = 5

# The intervals for updating cluster stats
CLUSTER_NODES_STATS_CACHE_SIZE = 1
CLUSTER_PROCESSES_STATS_CACHE_SIZE = 1
CLUSTER_PROXIES_STATS_CACHE_SIZE = 1

# Path to haproxy stats socket
HAPROXY_STATS_SOCKET_PATH = '/etc/haproxy/stats'

# Quiet logging intervals
LOCAL_STATS_DEBUG_INTERVAL = 5*60
CLUSTER_STATS_DEBUG_INTERVAL = 15*60

# Path to dictionary to write profile log
PROFILE_LOG_DIR = '/var/log/appscale/profile'


class _MissedValue(object):
  """
  Instance of this private class denotes missed value.
  It's used to denote values of stats properties which are missed
  in haproxy stats.
  """

  def __nonzero__(self):
    return False

  def __repr__(self):
    return ''


MISSED = _MissedValue()
