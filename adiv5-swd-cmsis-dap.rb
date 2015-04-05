require 'libusb'
require 'log'

class Adiv5SwdCmsisDap
  class CMSISError < StandardError
  end

  class ProtocolError < StandardError
  end

  class Wait < StandardError
  end

  class Fault < StandardError
  end


  def initialize(args)
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

    setup_connection(args)
  end

  def setup_connection(args)
    @info = cmd_dap_info
    @packet_size = @info[:packet_size]
    @packet_count = @info[:packet_count]

    cmd_connect(:swd)
    cmd_dap_swj_sequence(255.chr * 7) # at least 50 high
    cmd_dap_swj_sequence([0xe79e].pack('v')) # switch-to-swd magic
    cmd_dap_swj_sequence(255.chr * 7) # at least 50 high
    cmd_dap_swj_sequence(0.chr) # at least 1 low
    read(:dp, 0, {})            # read IDCODE
  end

  def max_transfer_block(dir)
    overhead = {write: 5, read: 4}
    (@packet_size - overhead[dir]) / 4
  end

  def read(port, addr, opt)
    r = {port: port, dir: :read, addr: addr}
    if opt[:count]
      count = opt[:count]
      retval = []
      while count > 0
        c = count
        if c > max_transfer_block(:read)
          c = max_transfer_block(:read)
        end
        count -= c
        r[:count] = c
        ret = cmd_dap_transfer_block(r)
        break if ret[:count] != r[:count] || ret[:response] != :ok
        retval += ret[:val]
      end
      ret[:val] = retval
    else
      ret = cmd_dap_transfer([r]).first
    end
    case ret[:response]
    when :wait
      raise Wait
    when :fault
      raise Fault
    when :proto_err, :no_exec
      raise ProtocolError
    when :ok
      # pass
    end
    ret[:val]
  end

  def write(port, addr, val)
    r = {port: port, dir: :write, addr: addr, val: val}
    if Array === val
      count = val.count
      while count > 0
        c = count
        if c > max_transfer_block(:write)
          c = max_transfer_block(:write)
        end
        count -= c
        r[:count] = c
        ret = cmd_dap_transfer_block(r)
        break if ret[:count] != r[:count] || ret[:response] != :ok
      end
    else
      ret = cmd_dap_transfer([r]).first
    end
    case ret[:response]
    when :wait
      raise Wait
    when :fault
      raise Fault
    when :proto_err, :no_exec
      raise ProtocolError
    when :ok
      # pass
    end
  end

  CMD_DAP_INFO = 0
  CMD_CONNECT = 2
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
      capabilities: [0xf0, ->(d){{swd: 1, jtag: 2}.select{|k, v| d.unpack('c').first & v != 0}.map(&:first)}],
      packet_count: [0xfe, ->(d){d.unpack('c').first}],
      packet_size: [0xff, ->(d){d.unpack('v').first}]
    }

    ret = {}
    ids.each do |k, v|
      v, cb = v if v.is_a? Array
      buf = submit(CMD_DAP_INFO, [v].pack('c*'))
      len, rest = buf.unpack('ca*')
      rest = rest[0,len]
      rest = cb.(rest) if cb
      ret[k] = rest
    end
    ret
  end

  def cmd_connect(mode)
    modetab = {swd: 1, jtag: 2}
    r = submit(CMD_CONNECT, [modetab[mode]].pack('c'))
    raise RuntimeError "could not connect as #{mode}" if r.unpack('c').first == 0
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
      rc |= 2 if r[:dir] == :read
      rc |= r[:addr]
      data += [rc].pack('c')
      data += [r[:val]].pack('V') if r[:dir] == :write
    end
    result = submit(CMD_DAP_TRANSFER, data)
    count, rest = result.unpack('ca*')

    ret = []
    reqs.each_with_index do |r, i|
      r = r.dup
      ret << r
      if i >= count
        r[:response] = :no_exec
        next
      end

      resp, rest = rest.unpack('ca*')
      swd_ack = {1 => :ok, 2 => :wait, 4 => :fault}
      r[:response] = swd_ack[resp&7]
      r[:response] = :proto_err if resp & 8 != 0
      r[:mismatch] = true if resp & 16
      if r[:dir] == :read
        val, rest = rest.unpack('Va*')
        r[:val] = val
      end
    end

    ret
  end

  def cmd_dap_transfer_block(req)
    if req[:dir] == :read
      count = req[:count]
    else
      count = req[:val].count
    end

    data = [0, count].pack('cv')
    rc = 0
    rc |= 1 if req[:port] == :ap
    rc |= 2 if req[:dir] == :read
    rc |= req[:addr]
    data += [rc].pack('c')
    data += req[:val].pack('V*') if req[:dir] == :write

    result = submit(CMD_DAP_TRANSFER_BLOCK, data)
    ret = req.dup

    count, resp, rest = result.unpack('vca*')
    swd_ack = {1 => :ok, 2 => :wait, 4 => :fault}
    ret[:response] = swd_ack[resp&7]
    ret[:response] = :proto_err if resp & 8 != 0
    ret[:count] = count
    if req[:dir] == :read
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

    retcmd, rest = retdata.unpack('ca*')
    raise RuntimeError, "invalid reply" if retcmd != cmd
    rest
  end

  def check(reply)
    if reply.unpack('c').first != 0
      raise CMSISError, "error reply from DAP"
    end
    reply
  end
end
