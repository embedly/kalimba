require 'camping'

Camping.goes :Kalimba

module Kalimba::Controllers
  class Index < R '/'
    def get
      render :hello
    end
  end
end

module Kalimba::Views
  def hello
    p "Hello World!"
  end
end
