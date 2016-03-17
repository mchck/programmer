$: << '..'
require 'minitest/autorun'
require 'adiv5-ap'

class TestAdiv5Ap < MiniTest::Test
  def setup
    @m = MiniTest::Mock.new
    @m.expect(:ap_select, nil, [0, 0])
    @m.expect(:read, 1111, [:ap, 0, {}])
    @m.expect(:ap_select, nil, [0, 0])
    @m.expect(:write, nil, [:ap, 0, 82])
    @m.expect(:ap_select, nil, [0, 244])
    @m.expect(:read, 0, [:ap, 4, {}])
    @d = Adiv5::MemAP.new(@m, 0)
  end

  def test_write
    @m.expect(:ap_select, nil, [0, 4])
    @m.expect(:write, nil, [:ap, 4, 0x1234])
    @m.expect(:ap_select, nil, [0, 12])
    @m.expect(:write, nil, [:ap, 12, 0x5678])
    @d.write(0x1234, 0x5678)
  end

  def test_write_byte
    @m.expect(:ap_select, nil, [0, 4])
    @m.expect(:write, nil, [:ap, 4, 0x1234])
    @m.expect(:ap_select, nil, [0, 0])
    @m.expect(:read, 82, [:ap, 0, {}])
    @m.expect(:ap_select, nil, [0, 0])
    @m.expect(:write, nil, [:ap, 0, 80])
    @m.expect(:ap_select, nil, [0, 12])
    @m.expect(:write, nil, [:ap, 12, 0x5678])
    @d.write(0x1234, 0x5678, size: :byte)
  end
end
