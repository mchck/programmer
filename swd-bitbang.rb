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

  def transact(dir, port, addr, data=nil)
    cmd = 0x81
    case port
    when :ap
      cmd |= 0x2
    end
    case dir
    when :in
      cmd |= 0x4
    end
    cmd |= ((addr & 0xc) << 1)
    parity = cmd
    parity ^= parity >> 4
    parity ^= parity >> 2
    parity ^= parity >> 1
    if parity & 1 != 0
      cmd |= 0x20
    end

    Log(:phys, 1){ 'transact %02x = %s %s %x' % [cmd, dir, port, addr] }

    ack = @lower.write_cmd cmd.chr

    case ack
    when Adiv5Swd::ACK_OK
      case dir
      when :out
        @lower.write_word_and_parity(data, calc_parity(data))
      when :in
        data, par = @lower.read_word_and_parity
        cal_par = calc_parity data
        if par != cal_par
          raise Adiv5::ParityError
        end
      end
    when Adiv5Swd::ACK_WAIT, Adiv5Swd::ACK_FAULT
      # nothing
    else
      # we read data right now, just to make sure that we will never
      # work against the protocol

      @lower.read_word_and_parity
    end
    [ack, data]
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
