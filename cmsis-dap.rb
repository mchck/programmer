require 'libusb'
require 'log'

class CmsisDap
  class CMSISError < StandardError
  end

  def initialize(args)
    select_device(args)
    setup_connection(args)
  end

  def select_device(args)
    # search for adapter
    @usb = LIBUSB::Context.new
    match = {}
    match[:idVendor] = [args[:vid]] if args[:vid]
    match[:idProduct] = [args[:pid]] if args[:pid]
    devs = @usb.devices(match).select do |dev|
      r = dev.product.match /CMSIS-DAP/
      settings = dev.configurations[0].interfaces[0].settings[0]
      r &&= settings.bInterfaceClass == LIBUSB::CLASS_HID
      r &&= dev.serial_number == args[:serial] if args[:serial]
      r
    end

    if devs.empty?
      raise RuntimeError, "cannot find CMSIS-DAP device"
    end

    dev = devs[0]

    @dev = dev.open
    #@dev.configuration = 0
    @iface = dev.interfaces[0]
    @dev.detach_kernel_driver(@iface) if @dev.kernel_driver_active?(@iface)
    @outep = @iface.settings[0].endpoints.select{|e| e.direction == :out}.first
    @inep = @iface.settings[0].endpoints.select{|e| e.direction == :in}.first
    @dev.claim_interface(@iface)
    @packet_size = 64
  end

  def setup_connection(args)
    @info = cmd_dap_info
    @packet_size = @info[:packet_size]
    @packet_count = @info[:packet_count]

    cmd_dap_swj_clock(args[:speed]*1000) if args[:speed]

    cmd_connect(:swd)
    reset_target(true) if args[:reset] && args[:reset] != 0
  end

  def raw_out(seq, len=seq.bytesize*8)
    cmd_dap_swj_sequence(seq, len)
  end

  def flush!
  end

  def reset_target(assert)
    cmd_dap_swj_pins(assert ? 0 : 0x80, 0x80, 0)
  end

  def transfer_block(req)
    ret = req.dup
    ret[:val] = []

    count = req[:count]
    while count > 0
      c = count
      if c > max_transfer_block(:read)
        c = max_transfer_block(:read)
      end
      r[:count] = c
      thisret = cmd_dap_transfer_block(r)
      ret[:ack] = thisret[:ack]
      if thisret[:count] > 0
        ret[:val] += thisret[:val] if req[:op] == :read
        count -= thisret[:count]
      end
      if thisret[:ack] != Adiv5Swd::ACK_OK
        break
      end
    end
    ret
  end

  def transfer(req)
    cmd_dap_transfer([req]).first
  end

  def max_transfer_block(op)
    overhead = {write: 5, read: 4}
    (@packet_size - overhead[op]) / 4
  end

  def maybe_wait_writebuf(req)
    # XXX if req is not waitable
  end

  CMD_DAP_INFO = 0
  CMD_CONNECT = 2
  CMD_DAP_SWJ_PINS = 0x10
  CMD_DAP_SWJ_CLOCK = 0x11
  CMD_DAP_SWJ_SEQUENCE = 0x12
  CMD_DAP_TRANSFER = 5
  CMD_DAP_TRANSFER_BLOCK = 6

  def cmd_dap_info
    ids = {
      vendor: 1,
      product: 2,
      serial: 3,
      fwver: 4,
      target_vendor: 5,
      target_device: 6,
      capabilities: [0xf0, ->(d){{swd: 1, jtag: 2}.select{|k, v| d.unpack('C').first & v != 0}.map(&:first)}],
      packet_count: [0xfe, ->(d){d.unpack('C').first}],
      packet_size: [0xff, ->(d){d.unpack('v').first}]
    }

    ret = {}
    ids.each do |k, v|
      v, cb = v if v.is_a? Array
      buf = submit(CMD_DAP_INFO, [v].pack('c*'))
      len, rest = buf.unpack('Ca*')
      rest = rest[0,len]
      rest = cb.(rest) if cb
      ret[k] = rest
    end
    ret
  end

  def cmd_connect(mode)
    modetab = {swd: 1, jtag: 2}
    r = submit(CMD_CONNECT, [modetab[mode]].pack('c'))
    raise RuntimeError "could not connect as #{mode}" if r.unpack('C').first == 0
  end

  def cmd_dap_swj_pins(out, select, wait)
    val = submit(CMD_DAP_SWJ_PINS, [out, select, wait].pack('ccV'))
    val.unpack('C').first
  end

  def cmd_dap_swj_clock(freq)
    submit(CMD_DAP_SWJ_CLOCK, [freq].pack('V'))
  end

  def cmd_dap_swj_sequence(seq, len=seq.bytesize*8)
    check submit(CMD_DAP_SWJ_SEQUENCE, [len, seq].pack('ca*'))
  end

  def cmd_dap_transfer(reqs)
    data = [0, reqs.length].pack('cc')
    reqs.each do |r|
      rc = 0
      rc |= 1 if r[:port] == :ap
      rc |= 2 if r[:op] == :read
      rc |= r[:addr]
      data += [rc].pack('c')
      data += [r[:val]].pack('V') if r[:op] == :write
    end
    result = submit(CMD_DAP_TRANSFER, data)
    count, last_resp, rest = result.unpack('CCa*')

    ret = []
    reqs.each_with_index do |r, i|
      r = r.dup
      r[:ack] = Adiv5Swd::ACK_OK
      ret << r
      if i == count
        r[:ack] = last_resp
        r[:ack] = Adiv5Swd::ParityError if last_resp & 8 != 0
        r[:mismatch] = true if last_resp & 16 != 0
        next if r[:ack] != Adiv5Swd::ACK_OK
      elsif i > count
        r[:ack] = :no_exec
        next
      end

      if r[:op] == :read
        val, rest = rest.unpack('Va*')
        r[:val] = val
      end
    end

    ret
  end

  def cmd_dap_transfer_block(req)
    if req[:op] == :read
      count = req[:count]
    else
      count = req[:val].count
    end

    data = [0, count].pack('cv')
    rc = 0
    rc |= 1 if req[:port] == :ap
    rc |= 2 if req[:op] == :read
    rc |= req[:addr]
    data += [rc].pack('c')
    data += req[:val].pack('V*') if req[:op] == :write

    result = submit(CMD_DAP_TRANSFER_BLOCK, data)
    ret = req.dup

    count, resp, rest = result.unpack('vCa*')
    ret[:ack] = resp
    ret[:ack] = Adiv5Swd::ParityError if resp & 8 != 0
    ret[:count] = count
    if req[:op] == :read
      ret[:val] = rest.unpack("V#{count}")
    end
    ret
  end

  def submit(cmd, data)
    data = [cmd].pack('c')+data

    Log(:swd, 3){ "submit cmd %s" % data.unpack('H*').first }
    if @outep
      @dev.interrupt_transfer(endpoint: @outep, dataOut: data)
    else
      @dev.control_transfer(bmRequestType: LIBUSB::REQUEST_TYPE_CLASS | LIBUSB::RECIPIENT_INTERFACE,
                            wIndex: @iface.bInterfaceNumber,
                            wValue: 0,
                            bRequest: 0x09, # set report
                            dataOut: data)
    end
    if @inep
      retdata = @dev.interrupt_transfer(endpoint: @inep, dataIn: @packet_size)
    else
      retdata = @dev.control_transfer(bmRequestType: LIBUSB::REQUEST_TYPE_CLASS | LIBUSB::RECIPIENT_INTERFACE | 1, # in
                                      wIndex: @iface.bInterfaceNumber,
                                      wValue: 0,
                                      bRequest: 0x01, # get report
                                      dataIn: @packet_size)
    end
    Log(:swd, 3){ "reply %s" % retdata.unpack('H*').first }

    retcmd, rest = retdata.unpack('Ca*')
    raise RuntimeError, "invalid reply" if retcmd != cmd
    rest
  end

  def check(reply)
    if reply.unpack('C').first != 0
      raise CMSISError, "error reply from DAP"
    end
    reply
  end
end
