require 'kalimba'
require 'sass/plugin/rack'

# config
Sass::Plugin.options.merge!(
  :template_location => File.expand_path('../sass', __FILE__),
  :css_location => File.expand_path('../static/css', __FILE__),
  :always_update => true,
  :always_check => true
)
dbconfig = YAML.load(File.read('config/database.yml'))
environment = ENV['DATABASE_URL'] ? 'production' : 'development'
Kalimba::Models::Base.establish_connection dbconfig[environment]
Kalimba.create

# start
use Sass::Plugin::Rack
use Rack::Static, :urls => ["/static"]
run Kalimba
