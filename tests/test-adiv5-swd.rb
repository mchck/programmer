$: << '..'
require 'minitest/autorun'
require 'adiv5-swd'

class TestAdiv5Swd < MiniTest::Test
  OK = 1
  WAIT = 2
  FAULT = 4

  def setup
    @m = MiniTest::Mock.new

    # switch_to_swd
    @m.expect(:raw_out, nil, [255.chr*7])
    @m.expect(:raw_out, nil, [[0xe79e].pack('v')])

    # reset
    @m.expect(:raw_out, nil, [255.chr*7])
    @m.expect(:raw_out, nil, [0.chr])
    @m.expect(:flush!, nil)
    @m.expect(:transact, [OK, 0], [:in, :dp, 0])

    # clear abort
    @m.expect(:transact, [OK], [:out, :dp, 0, 0x1e])

    # reset dp bank
    @m.expect(:transact, [OK], [:out, :dp, 8, 0])

    @m.expect(:flush!, nil)

    @d = Adiv5Swd.new(@m)
  end

  def teardown
    @m.verify
  end

  def test_write
  end
end
