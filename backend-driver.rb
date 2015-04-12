require 'swd-mchck-bitbang'
require 'swd-buspirate'
require 'adiv5-swd-cmsis-dap'
begin
  require 'swd-ftdi'
rescue LoadError
  # Not required, we'll just lack support for FTDI
end

module BackendDriver
  class << self
    def create(name, opts)
      case name
      when 'ftdi', 'busblaster'
        Adiv5Swd.new(BitbangSwd.new(FtdiSwd.new(opts)))
      when 'buspirate'
        Adiv5Swd.new(BitbangSwd.new(BusPirateSwd.new(opts)))
      when 'mchck'
        Adiv5Swd.new(BitbangSwd.new(MchckBitbangSwd.new(opts)))
      when 'cmsis-dap'
        Adiv5SwdCmsisDap.new(opts)
      end
    end

    def from_string_set(a)
      opts = {}
      a.each do |s|
        s.strip!
        name, val = s.split(/[=]/, 2) # emacs falls over with a /=/ regexp :/
        if !val || val.empty?
          raise RuntimeError, "invalid option `#{s}'"
        end
        begin
          val = Integer(val)
        rescue
          # just trying...
        end
        opts[name.to_sym] = val
      end
      name = opts.delete(:name)
      create(name, opts)
    end

    def from_string(s)
      from_string_set(s.split(/:/))
    end
  end
end
