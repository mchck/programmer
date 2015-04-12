require 'adiv5'
require 'log'

class BitbangSwd
  # We need to write on the negative edge, i.e. before asserting CLK.
  # We need to read on the positive edge, i.e. after having asserted CLK.

  def initialize(lower)
    @lower = lower
  end

  def raw_out(seq, seqlen=nil)
    seqlen ||= seq.length * 8
    Log(:phys, 1){ "swd raw: %s" % seq.unpack("B#{seqlen}").first }
    if seqlen >= 8
      @lower.write_bytes(seq[0..(seqlen / 8)])
    end
    if seqlen % 8 > 0
      @lower.write_bits(seq[-1], seqlen % 8)
    end
  end

  def transfer_block(req)
    seq = req[:val]
    seq = seq.times unless seq.respond_to? :each

    ret = req.dup
    ret[:val] = []
    seq.each do |thisval|
      r = req.dup
      r[:val] = thisval
      thisret = transfer(r)
      ret[:ack] = thisret[:ack]
      if thisret[:ack] == Adiv5Swd::ACK_OK
        ret[:val] << thisret[:val] if req[:dir] == :in
      else
        break
      end
    end
    ret
  end

  def transfer(req)
    cmd = 0x81
    case req[:port]
    when :ap
      cmd |= 0x2
    end
    case req[:dir]
    when :in
      cmd |= 0x4
    end
    cmd |= ((req[:addr] & 0xc) << 1)
    parity = cmd
    parity ^= parity >> 4
    parity ^= parity >> 2
    parity ^= parity >> 1
    if parity & 1 != 0
      cmd |= 0x20
    end

    Log(:phys, 1){ 'transfer %02x = %s %s %x' % [cmd, req[:dir], req[:port], req[:addr]] }

    ret = req.dup
    ret[:ack] = @lower.write_cmd cmd.chr

    case ret[:ack]
    when Adiv5Swd::ACK_OK
      case req[:dir]
      when :out
        @lower.write_word_and_parity(req[:val], calc_parity(req[:val]))
      when :in
        data, par = @lower.read_word_and_parity
        cal_par = calc_parity data
        if par != cal_par
          ret[:ack] = Adiv5Swd::ParityError
        end
        ret[:val] = data
      end
    when Adiv5Swd::ACK_WAIT, Adiv5Swd::ACK_FAULT
      # nothing
    else
      # we read data right now, just to make sure that we will never
      # work against the protocol

      @lower.read_word_and_parity
    end
    ret
  end

  def calc_parity(data)
    data ^= data >> 16
    data ^= data >> 8
    data ^= data >> 4
    data ^= data >> 2
    data ^= data >> 1
    data & 1
  end

  def hexify(str)
    str.unpack('C*').map{|e| "%02x" % e}.join(' ')
  end
end
