require 'rubygems'
require 'rake'
require 'rdoc/task'
require 'rake/testtask'


namespace :appcontroller do


  APPCONTROLLER_TEST_SUITE = "AppController/test/ts_all.rb"


  desc "Generates AppController rdoc"
  Rake::RDocTask.new(:doc) { |rd|
    rd.rdoc_files.include("AppController/djinn.rb", 
      "AppController/djinnServer.rb", "AppController/lib")
    rd.rdoc_dir = "AppController/doc"
  }


  desc "Runs AppController unit tests"
  Rake::TestTask.new("test") do |t|
    t.pattern = APPCONTROLLER_TEST_SUITE
    t.verbose = true
    t.warning = false
  end


end

namespace :appmanager do
  
  task :test do
   sh "nosetests AppManager/test/unit"
  end

end

namespace :apps do

  task :test do
    sh "nosetests Apps/sensor/tests " +
      "Apps/sensor/common/tests"
  end
  
end

namespace :infrastructuremanager do

  task :test do
    sh "nosetests InfrastructureManager"
  end

end

namespace :appdb do

  task :test do
    sh "nosetests AppDB/test/unit"
  end

end

namespace :apptaskqueue do

  task :test do
    sh "nosetests AppTaskQueue/test/unit"
  end

end

namespace :go do

  task :test do
    goroot = '/root/appscale/AppServer/goroot'
    sh "PATH=#{goroot}/bin:${PATH}; cd #{goroot}/src; ./run.bash --no-rebuild"
  end

end

namespace :hermes do

  task :test do
    sh "nosetests Hermes/test/unit"
  end

end

namespace :searchservice do

  task :test do
    sh "nosetests SearchService/test/unit"
  end

end

namespace :appserver do

  task :test do
    sh "nosetests AppServer/google/appengine/api/taskqueue/test " +
      "AppServer/google/appengine/api/xmpp/test"
  end

end


namespace :lib do

  task :test do
    sh "nosetests lib/test/unit"
  end

end

namespace :appdashboard do

  task :test do
    sh "nosetests AppDashboard/test/unit"
  end

  task :coverage do |test|
    sh "rm -rf AppDashboard/coverage"
    sh "coverage erase"
    sh "coverage run --include='AppDashboard/lib/*,AppDashboard/dashboard.py' --omit='*tests*' AppDashboard/test/test_suite.py"
    sh "coverage report -m"
    sh "coverage html --directory=AppDashboard/coverage"
  end

end

namespace :xmppreceiver do

  task :coverage do
    sh "rm -rf XMPPReceiver/coverage"
    sh "cd XMPPReceiver && coverage -e"
    sh "cd XMPPReceiver && coverage run --include='xmpp_receiver.py' --omit='*tests*' --omit='*Python*' test/test_suite.py"
    sh "cd XMPPReceiver && coverage report -m"
    sh "cd XMPPReceiver && coverage html"
    sh "cd XMPPReceiver && mv htmlcov coverage"
  end

  task :test do
    sh "nosetests XMPPReceiver"
  end

end

python_tests = [
  'appdashboard:test',
  'appdb:test',
  'appmanager:test',
  'appserver:test',
  'apptaskqueue:test',
  'hermes:test',
  'infrastructuremanager:test',
  'lib:test',
  'searchservice:test',
  'xmppreceiver:test',
  'apps:test'
]
ruby_tests = ['appcontroller:test']
go_tests = ['go:test']

task :brief => python_tests + ruby_tests

task :default => python_tests + ruby_tests + go_tests
