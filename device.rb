$: << File.realpath('..', __FILE__)
require 'kinetis'
require 'nrf51'
require 'log'

module Device
  class << self
    def detect(bkend)
      Log(:device, 1){ "detecting device" }

      devices = [Kinetis, NRF51]
      begin
        if !devices.empty?
          d = devices.pop
          Log(:device, 2){'trying %s' % d}
          dev = d.new(bkend)
          Log(:device, 1){'detected %s' % dev.class}
          return dev
        end
      rescue Exception => e
        Log(:device, 2){([e]+e.backtrace).join("\n")}
        retry
      end

      raise RuntimeError, "Unable to detect device."
    end
  end
end
