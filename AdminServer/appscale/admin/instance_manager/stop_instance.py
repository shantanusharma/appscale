""" Stops an AppServer instance. """
import argparse
import os
import psutil
import signal

from appscale.common.constants import PID_DIR

# The number of seconds to wait for an instance to terminate.
DEFAULT_WAIT_TIME = 20


def stop_instance(watch, timeout):
  """ Stops an AppServer process.

  Args:
    watch: A string specifying the Monit watch entry.
    timeout: An integer specifying the time to wait for requests to finish.
  Raises:
    IOError if the pidfile does not exist.
    OSError if the process does not exist.
  """
  pidfile_location = os.path.join(PID_DIR, '{}.pid'.format(watch))
  with open(pidfile_location) as pidfile:
    pid = int(pidfile.read().strip())

  group = os.getpgid(pid)
  process = psutil.Process(pid)
  process.terminate()
  try:
    process.wait(timeout)
  except psutil.TimeoutExpired:
    process.kill()

  try:
    os.killpg(group, signal.SIGKILL)
  except OSError:
    # In most cases, the group will already be gone.
    pass

  os.remove(pidfile_location)


def main():
  """ Stops an AppServer instance. """
  parser = argparse.ArgumentParser(description='Stops an AppServer instance')
  parser.add_argument('--watch', required=True, help='The Monit watch entry')
  parser.add_argument('--timeout', default=20,
                      help='The seconds to wait before killing the instance')
  args = parser.parse_args()
  stop_instance(args.watch, args.timeout)
