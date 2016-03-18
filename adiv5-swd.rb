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
      ack, _ = @drv.transfer(op: :read, port: :dp, addr: IDCODE)       # read DPIDR
      raise true if ack != ACK_OK
    rescue
      # If we fail, try again.  We might have been in an unfortunate state.
      @drv.raw_out(255.chr * 7) # at least 50 high
      @drv.raw_out(0.chr)       # at least 1 low
      @drv.transfer(op: :read, port: :dp, addr: IDCODE)       # read DPIDR
    end
  end

  def read(port, addr, opt={})
    readcount = opt[:count] || 1
    ret = []

    Log(:swd, 2){ 'read %s %x (%d words)...' % [port, addr, readcount] }
    req = {op: :read, port: port, addr: addr}
    if !opt[:count]
      reply = @drv.transfer(req)
    else
      req[:count] = readcount
      reply = @drv.transfer_block(req)
    end

    case reply[:ack]
    when ACK_OK
      # yey
    when ACK_FAULT
      # check WRERROR
      raise Adiv5::Fault
    when ACK_WAIT
      raise Adiv5::Wait
    when ParityError
    # XXX retry
      raise RuntimeError, "handle partiy error"
    else
      # random other ack - protocol error
      # XXX retry
      raise RuntimeError, "handle protocol error"
    end

    ret = reply[:val]

    Log(:swd, 1){ v = ret; v = [v] if !v.respond_to? :map; ['read  %s %x <' % [port, addr], *v.map{|e| "%08x" % e}] }

    ret
  end

  def write(port, addr, val)
    Log(:swd, 1){ v = val; v = [v] if !v.respond_to? :map; ['write %s %x =' % [port, addr], *v.map{|e| "%08x" % e}] }
    req = {op: :write, port: port, addr: addr, val: val}
    if !val.is_a? Array
      @drv.transfer(req)
    else
      @drv.transfer_block(req)
    end
  end
end

# We require this here so that all our consumers can directly use
# BackendDriver.  However, we cannot require this before the
# declaration of the class, or dependency loops get in our way.

if $0 == __FILE__
  s = Adiv5Swd.new(BackendDriver.from_string(ARGV[0]))
end
