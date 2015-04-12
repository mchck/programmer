$: << '..'
require 'minitest/autorun'
require 'swd-bitbang'

class TestBitbang < MiniTest::Test
  OK = 1
  WAIT = 2
  FAULT = 4

  def setup
    @m = MiniTest::Mock.new
    @d = BitbangSwd.new(@m)
  end

  def teardown
    @m.verify
  end

  def test_transfer_write_ok
    @m.expect(:write_cmd, OK, [0x81.chr])
    @m.expect(:write_word_and_parity, nil, [12, 0])
    ret = @d.transfer(dir: :out, port: :dp, addr: 0, val: 12)
    assert_equal OK, ret[:ack]
  end

  def test_transfer_read_ok
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [12, 0])
    ret = @d.transfer(dir: :in, port: :dp, addr: 0)
    assert_equal OK, ret[:ack]
    assert_equal 12, ret[:val]
  end

  def test_transfer_wait
    @m.expect(:write_cmd, WAIT, [0x81.chr])
    ret = @d.transfer(dir: :out, port: :dp, addr: 0, val: 12)
    assert_equal WAIT, ret[:ack]
  end

  def test_transfer_fault
    @m.expect(:write_cmd, FAULT, [0x81.chr])
    ret  = @d.transfer(dir: :out, port: :dp, addr: 0, val: 12)
    assert_equal FAULT, ret[:ack]
  end

  def test_transfer_protoerr
    @m.expect(:write_cmd, 0, [0x81.chr])
    @m.expect(:read_word_and_parity, [3, 1])
    ret = @d.transfer(dir: :out, port: :dp, addr: 0, val: 12)
    assert_equal 0, ret[:ack]
  end

  def test_transfer_parityerr
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [3, 1])
    ret = @d.transfer(dir: :in, port: :dp, addr: 0)
    assert_equal Adiv5Swd::ParityError, ret[:ack]
  end

  def test_transfer_block
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [3, 0])
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [4, 1])
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [5, 0])
    ret = @d.transfer_block(dir: :in, port: :dp, addr: 0, val: 3)
    assert_equal OK, ret[:ack]
    assert_equal [3,4,5], ret[:val]
  end
end
