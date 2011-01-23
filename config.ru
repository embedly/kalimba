require 'kalimba'
require 'fileutils'

# config
environment = ENV['DATABASE_URL'] ? 'production' : 'development'
Kalimba::Models::Base.establish_connection dbconfig[environment]
Kalimba.create

# start
use Rack::Static, :urls => ["/static"]
run Kalimba
