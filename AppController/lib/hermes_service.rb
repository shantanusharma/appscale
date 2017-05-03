#!/usr/bin/ruby -w

$:.unshift File.join(File.dirname(__FILE__))
require 'helperfunctions'
require 'monit_interface'

# Starts and stops the Hermes (messenger) service.
module HermesService

  # Starts the Hermes service on this machine. We don't want to monitor
  # it ourselves, so just tell monit to start it and watch it.
  def self.start()
    hermes = self.scriptname()
    start_cmd = "/usr/bin/python2 #{hermes}"
    MonitInterface.start(:hermes, start_cmd)
  end

  # Stops the Hermes service running on this machine. Since it's
  # managed by monit, just tell monit to shut it down.
  def self.stop()
    MonitInterface.stop(:hermes)
  end

  def self.scriptname()
    return "#{APPSCALE_HOME}/Hermes/hermes.py"
  end

end
