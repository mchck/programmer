$: << '..'
require 'minitest/autorun'
require 'swd-bitbang'

class TestBitbang < MiniTest::Unit::TestCase
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

  def test_transact_write_ok
    @m.expect(:write_cmd, OK, [0x81.chr])
    @m.expect(:write_word_and_parity, nil, [12, 0])
    ack, _ = @d.transact(:out, :dp, 0, 12)
    assert_equal OK, ack
  end

  def test_transact_read_ok
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [12, 0])
    ack, val = @d.transact(:in, :dp, 0)
    assert_equal OK, ack
    assert_equal 12, val
  end

  def test_transact_wait
    @m.expect(:write_cmd, WAIT, [0x81.chr])
    ack, _ = @d.transact(:out, :dp, 0, 12)
    assert_equal WAIT, ack
  end

  def test_transact_fault
    @m.expect(:write_cmd, FAULT, [0x81.chr])
    ack, _  = @d.transact(:out, :dp, 0, 12)
    assert_equal FAULT, ack
  end

  def test_transact_protoerr
    @m.expect(:write_cmd, 0, [0x81.chr])
    @m.expect(:read_word_and_parity, [3, 1])
    ack, _ = @d.transact(:out, :dp, 0, 12)
    assert_equal 0, ack
  end

  def test_transact_parityerr
    @m.expect(:write_cmd, OK, [0xa5.chr])
    @m.expect(:read_word_and_parity, [3, 1])
    assert_raises(Adiv5::ParityError) {
      @d.transact(:in, :dp, 0)
    }
  end
end
