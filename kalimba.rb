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
  def layout
    html do
      head do
        title { "Kalimba - Rose Colored Glasses for Hacker News" }
      end

      body { self << yield }
    end
  end

  def hello
    p "Hello World!"
  end
end
