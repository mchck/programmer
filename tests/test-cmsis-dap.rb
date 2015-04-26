$: << '..'
require 'minitest/autorun'
require 'cmsis-dap'
require 'ostruct'

class CmsisDapNoUSB < CmsisDap
  def initialize(mockdev, args)
    @dev = mockdev
    super(args)
  end

  def select_device(args)
    @iface = OpenStruct.new(bInterfaceNumber: 0)
  end

  def setup_connection(args)
    @packet_size = 64
  end

  def submit(cmd, data)
    @dev.submit(cmd, data)
  end
end

class TestCmsisDap < MiniTest::Test
  OK = 1
  WAIT = 2
  FAULT = 4

  def setup
    @m = MiniTest::Mock.new
    @d = CmsisDapNoUSB.new(@m, {})
  end

  def teardown
    @m.verify
  end

  def test_transfer_ok
    @m.expect(:submit, [1,OK,0x12345678].pack('ccV'), [5, [0,1,2].pack('c*')])
    ret = @d.transfer(op: :read, addr: 0, port: :dp)
    assert_equal OK, ret[:ack]
    assert_equal 0x12345678, ret[:val]
  end

  def test_transfer_fault_but_exec
    @m.expect(:submit, [1,FAULT,0x12345678].pack('ccV'), [5, [0,1,2].pack('c*')])
    ret = @d.transfer(op: :read, addr: 0, port: :dp)
    assert_equal FAULT, ret[:ack]
  end

  def test_reset
    @m.expect(:submit, 0.chr, [0x10, [0, 0x80, 0].pack('ccV')])
    ret = @d.reset_target(true)
    assert_equal 0, ret
    @m.expect(:submit, 0x80.chr, [0x10, [0x80, 0x80, 0].pack('ccV')])
    ret = @d.reset_target(false)
    assert_equal 0x80, ret
  end
end

class Advi5SwdNoInit < Adiv5Swd
  def initialize(drv)
    @drv = drv
  end
end

class TestAdiv5SwdWithCmsisDap < MiniTest::Test
  OK = 1
  WAIT = 2
  FAULT = 4

  def setup
    @m = MiniTest::Mock.new
    @d = Advi5SwdNoInit.new(CmsisDapNoUSB.new(@m, {}))
  end

  def teardown
    @m.verify
  end

  def test_read_block_fault
    @m.expect(:submit, [3,FAULT,1,2,3].pack('vcV*'), [6, [0,4,2].pack('cvc')])
    assert_raises(Adiv5::Fault) do
      assert_equal [1,2,3,4], @d.read(:dp, 0, count: 4)
    end
  end

  def test_read_block_ok
    @m.expect(:submit, [4,OK,1,2,3,4].pack('vcV*'), [6, [0,4,2].pack('cvc')])
    assert_equal [1,2,3,4], @d.read(:dp, 0, count: 4)
  end
end
