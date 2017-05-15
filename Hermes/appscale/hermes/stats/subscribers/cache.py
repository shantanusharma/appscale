import time
from datetime import datetime

from appscale.hermes.stats.pubsub_base import StatsSubscriber

BIG_BANG_TIMESTAMP = 0


class StatsCache(StatsSubscriber):
  """
  It takes care of storing snapshots in limited cache and provides
  reading method with acknowledgment mechanism.
  Each node has local stats cache for each kind of stats it collects
  (node stats, processes stats and haproxy stats for LB nodes).
  It is used as a temporary storage
  for stats that haven't been read by master yet.
  """

  def __init__(self, snapshots_cache_size, ttl=None):
    self._snapshots_cache = []
    if snapshots_cache_size < 1:
      raise ValueError("Snapshots cache size can be fewer than 1")
    self._snapshots_cache_size = snapshots_cache_size
    self._ttl = ttl

  def receive(self, stats_snapshot):
    """ Appends stats_snapshot to the limited cache.
    If cache size is exceeded removes oldest snapshots.

    Args:
      stats_snapshot: an object with utc_timestamp attribute
    """
    self._snapshots_cache.append(stats_snapshot)
    self._clean_expired()
    if len(self._snapshots_cache) > self._snapshots_cache_size:
      # Remove oldest snapshots which exceed cache size
      diff = len(self._snapshots_cache) - self._snapshots_cache_size
      self._snapshots_cache = self._snapshots_cache[diff:]

  def bulk_receive(self, stats_snapshots):
    """ Appends stats_snapshots to the limited cache.
    If cache size is exceeded removes oldest snapshots.

    Args:
      stats_snapshots: a list of objects with utc_timestamp attribute
    """
    self._snapshots_cache += stats_snapshots
    self._clean_expired()
    if len(self._snapshots_cache) > self._snapshots_cache_size:
      # Remove oldest snapshots which exceed cache size
      diff = len(self._snapshots_cache) - self._snapshots_cache_size
      self._snapshots_cache = self._snapshots_cache[diff:]

  def get_stats_after(self, last_timestamp=BIG_BANG_TIMESTAMP, clean_older=True):
    """ Gets statistics snapshots which are newer than last_timestamp.
    Optionally it can remove older snapshots. In this case last_timestamp
    works like acknowledgment in TCP.

    Args:
      last_timestamp: unix epoch timestamp of the latest snapshot which was read
      clean_older: determines whether older snapshots should be removed
    Returns:
      a list of statistic snapshots newer than last_timastamp
    """
    self._clean_expired()
    try:
      # Need to return only snapshots which are newer than last_timestamp
      start_index = next((
        i for i in xrange(0, len(self._snapshots_cache))
        if self._snapshots_cache[i].utc_timestamp > last_timestamp
      ))
    except StopIteration:
      # There are no newer snapshots
      return []
    result = self._snapshots_cache[start_index:]
    if clean_older:
      self._snapshots_cache = self._snapshots_cache[start_index:]
    return result

  def get_latest(self):
    self._clean_expired()
    return self._snapshots_cache[-1]

  def _clean_expired(self):
    if not self._ttl:
      return
    now = time.mktime(datetime.utcnow().timetuple())
    while self._snapshots_cache:
      if now - self._snapshots_cache[0].utc_timestamp > self._ttl:
        del self._snapshots_cache[0]
      else:
        break


class ClusterStatsCache(StatsSubscriber):
  """
  Wraps collection of StatsCache instances. It's aimed to store
  latest stats snapshots from multiple cluster node.
  """

  def __init__(self, cache_size_per_node, ttl=None):
    self._node_caches = {}
    if cache_size_per_node < 1:
      raise ValueError("Cache size per node can be fewer than 1")
    self._cache_size_per_node = cache_size_per_node
    self._ttl = ttl

  def receive(self, nodes_stats_dict):
    """ Appends stats_snapshots to the limited caches.
    If cache size is exceeded removes oldest snapshots in this cache.

    Args:
      nodes_stats_dict: a dict, key is node_ip and
          value is a list of stats snapshots
    """
    new_node_caches_dict = {}
    for node_ip, stats_snapshots in nodes_stats_dict.iteritems():
      node_stats_cache = self._node_caches.get(node_ip)
      if not node_stats_cache:
        node_stats_cache = StatsCache(self._cache_size_per_node, self._ttl)
      node_stats_cache.bulk_receive(stats_snapshots)
      new_node_caches_dict[node_ip] = node_stats_cache
    self._node_caches = new_node_caches_dict

  def get_stats_after(self, last_timestamps_dict=None, clean_older=True):
    """ Gets statistics snapshots which are newer than last_timestamp.
    Optionally it can remove older snapshots. In this case last_timestamp
    works like acknowledgment in TCP.

    Args:
      last_timestamps_dict: a dict, key is node_ip and value is last timestamp
      clean_older: determines whether older snapshots should be removed
    Returns:
      a dict of lists of statistic snapshots newer than last_timastamp
    """
    nodes_stats = {}
    last_timestamps_dict = last_timestamps_dict or {}
    for node_ip, cache in self._node_caches.iteritems():
      last_timestamp = last_timestamps_dict.get(node_ip, BIG_BANG_TIMESTAMP)
      nodes_stats[node_ip] = cache.get_stats_after(last_timestamp, clean_older)
    return nodes_stats

  def get_latest(self):
    latest_stats = {}
    no_fresh_stats_for = []
    for node_ip, cache in self._node_caches.iteritems():
      try:
        snapshot = cache.get_latest()
        latest_stats[node_ip] = snapshot
      except IndexError:
        no_fresh_stats_for.append(node_ip)
    return latest_stats, no_fresh_stats_for
