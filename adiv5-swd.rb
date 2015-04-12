require 'log'
require 'adiv5'

class Adiv5Swd
  ABORT = 0
  IDCODE = 0
  SELECT = 8
  RESEND = 8
  RDBUFF = 12

  SWD_MAGIC = 0xe79e

  ACK_OK = 1
  ACK_WAIT = 2
  ACK_FAULT = 4
  ParityError = 8

  def initialize(drv)
    @drv = drv

    switch_to_swd
    write(:dp, ABORT, 0x1e)           # clear all errors
    write(:dp, SELECT, 0)             # select DP bank 0
    @drv.flush!
  end

  def switch_to_swd
    @drv.raw_out(255.chr * 7)        # at least 50 high
    @drv.raw_out([SWD_MAGIC].pack('v')) # magic number
    reset
  end

  def reset
    @drv.raw_out(255.chr * 7)        # at least 50 high
    @drv.raw_out(0.chr)              # at least 1 low
    @drv.flush!
    begin
      ack, _ = @drv.transact(:in, :dp, IDCODE)       # read DPIDR
      raise true if ack != ACK_OK
    rescue
      # If we fail, try again.  We might have been in an unfortunate state.
      @drv.raw_out(255.chr * 7) # at least 50 high
      @drv.raw_out(0.chr)       # at least 1 low
      @drv.transact(:in, :dp, IDCODE)       # read DPIDR
    end
  end

  def read(port, addr, opt={})
    readcount = opt[:count] || 1
    ret = []

    Log(:swd, 2){ 'read  %s %x (%d words)...' % [port, addr, readcount] }
    readcount.times do |i|
      ack, data = @drv.transact(:in, port, addr)
      # XXX check ack
      ret << data
    end
    # reads to the AP are posted, so we need to get the result in a
    # separate transaction.
    if port == :ap
      # first discard the first bogus result
      ret.shift
      # add last posted result
      ack, data = @drv.transact(:in, :dp, RDBUFF)
      # XXX check ack
      ret << data
    end
    Log(:swd, 1){ ['read  %s %x <' % [port, addr], *ret.map{|e| "%08x" % e}] }

    ret = ret.first if not opt[:count]
    ret
  end

  def write(port, addr, val)
    val = [val] unless val.respond_to? :each
    Log(:swd, 1){ ['write %s %x =' % [port, addr], *val.map{|e| "%08x" % e}] }
    val.each do |v|
      @drv.transact(:out, port, addr, v)
    end
  end
end

# We require this here so that all our consumers can directly use
# BackendDriver.  However, we cannot require this before the
# declaration of the class, or dependency loops get in our way.

if $0 == __FILE__
  s = Adiv5Swd.new(BackendDriver.from_string(ARGV[0]))
end
