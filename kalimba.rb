require 'camping'

Camping.goes :Hello

module Kalimba::Controllers
  class Index < R '/'
    def get
      render :hello
    end
  end
end

module Kalimba::Views
  def kalimba
    p "Hello World!"
  end
end
