require 'kalimba'
require 'fileutils'

# config
environment = ENV['DATABASE_URL'] ? 'production' : 'development'
if environment == 'development'
  require 'sass/plugin/rack'
  Sass::Plugin.options.merge!(
    :template_location => File.expand_path('../sass', __FILE__),
    :css_location => File.expand_path('../static/css', __FILE__),
    :always_update => false,
    :always_check => true
  )
  use Sass::Plugin::Rack
  use Rack::Reloader
end
dbconfig = YAML.load(File.read('config/database.yml'))
Kalimba::Models::Base.establish_connection dbconfig[environment]
Kalimba.create

# start
use Rack::Static, :urls => ["/static"]
run Kalimba
