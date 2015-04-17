$: << '..'
require 'minitest/autorun'
require 'cmsis-dap'

class TestCmsisDap < MiniTest::Test
  OK = 1
  WAIT = 2
  FAULT = 4

  def setup
    @m = MiniTest::Mock.new
    @d = CmsisDap.new({})
  end

  def teardown
    @m.verify
  end

  def test_transfer_ok(op: :read, port: :dp, addr: 0)

  end
end
