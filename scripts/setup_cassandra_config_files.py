#!/usr/bin/env python2
""" This script writes all the configuration files necessary to start Cassandra
on this machine."""

import argparse
import os
import sys

sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
import appscale_info
from constants import APPSCALE_HOME
from deployment_config import DeploymentConfig
from deployment_config import InvalidConfig

sys.path.append(os.path.join(os.path.dirname(__file__), '../AppDB'))
from cassandra_env.cassandra_interface import CASSANDRA_INSTALL_DIR

# Cassandra configuration files to modify.
CASSANDRA_TEMPLATES = os.path.join(APPSCALE_HOME, 'AppDB', 'cassandra_env',
                                   'templates')

if __name__ == "__main__":
  parser = argparse.ArgumentParser(
    description="Creates Cassandra's Monit configuration files")
  parser.add_argument('--local-ip', required=True,
                      help='The private IP address of this machine.')
  parser.add_argument('--master-ip', required=True,
                      help='The private IP address of the database master.')
  args = parser.parse_args()

  deployment_config = DeploymentConfig(appscale_info.get_zk_locations_string())
  cassandra_config = deployment_config.get_config('cassandra')
  if 'num_tokens' not in cassandra_config:
    raise InvalidConfig('num_tokens not specified in deployment config.')
  num_tokens = cassandra_config['num_tokens']

  replacements = {'APPSCALE-LOCAL': args.local_ip,
                  'APPSCALE-MASTER': args.master_ip,
                  'APPSCALE-NUM-TOKENS': num_tokens}

  for filename in os.listdir(CASSANDRA_TEMPLATES):
    source_file_path = os.path.join(CASSANDRA_TEMPLATES, filename)
    dest_file_path = os.path.join(CASSANDRA_INSTALL_DIR, 'cassandra', 'conf',
                                  filename)
    with open(source_file_path) as source_file:
      contents = source_file.read()
    for key, replacement in replacements.items():
      if replacement is None:
        replacement = ''
      contents = contents.replace(key, str(replacement))
    with open(dest_file_path, 'w') as dest_file:
      dest_file.write(contents)
