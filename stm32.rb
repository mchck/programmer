require 'adiv5'
require 'armv7'
require 'register'
require 'log'

class STM32F4 < ARMv7
  def detect
    @dap.IDR.to_i == 0x24770011 && @dap.read(0xE000ED00) == 0x410FC241 && self.identify != nil
  end

  def identify
    @device_id = @dap.read(0xE0042000) & 0x00000FFF
    case @device_id
      when 0x413 then "F405/F407/F415/F417"
      when 0x419 then "F42x/F43x"
      when 0x423 then "F401xB/F401xC"
      when 0x433 then "F401xD/F401xE"
      when 0x431 then "F411xC/F411xE"
      else nil
    end
  end

  def initialize(bkend, magic_halt=false)
    super(bkend)

    cpuid = @dap.read(0xE000ED00)
    if cpuid != 0x410FC241
      raise RuntimeError, "not a Cortex M4"
    end

    @device_id = self.identify
    if @device_id == nil
      raise RuntimeError, "not a supported STM32F4 device"
    end
    Log(:stm32, 1){ "found device ID: STM32%s" % @device_id }
    
    @flash = STM32F4::FlashController.new(@dap)
    @flash_size = (@dap.read(0x1FFF7A20) >> 16)
    Log(:stm32, 1){ "found flash size: %d KB" % @flash_size }
    @bank2 = (@flash_size > 1024)
    
    @flash_base = 0x08000000
    @flash_sectors = 4.times.map { |index| [@flash_base + index * 0x4000, 0x4000, index, 0] } + 
      [[@flash_base + 0x10000, 0x10000, 4, 0]] + 
      7.times.map { |index| [@flash_base + (index + 1) * 0x20000, 0x20000, index + 5, 0] } 
    
    if @bank2
      @flash_sectors += @flash_sectors.map { |addr, len, index, bank| [addr + 0x100000, len, index, 1] }
    end
    
    self.probe!
  end

  def mmap_ranges
    super +
      [
        {:type => :flash, :start => @flash_base, :length => 0x00200000, :blocksize => 0x100}, # XXXKF find block size
        {:type => :flash, :start => 0x1FFF0000, :length => 0x00010000}, # unique device ID and flash size
        {:type => :ram,   :start => 0x20000000, :length => 0x0001C000}, # 112 KB SRAM
        {:type => :ram,   :start => 0x2001C000, :length => 0x00004000}, # 16 KB SRAM
        {:type => :ram,   :start => 0x20020000, :length => 0x00010000}, # 64 KB SRAM
        {:type => :ram,   :start => 0x40000000, :length => 0x00008000}, # APB1
        {:type => :ram,   :start => 0x40010000, :length => 0x00006C00}, # APB2
        {:type => :ram,   :start => 0x40020000, :length => 0x00060000}, # AHB1
        {:type => :ram,   :start => 0x50000000, :length => 0x00060C00}, # AHB2
        {:type => :ram,   :start => 0x60000000, :length => 0x80000000}, # AHB3
      ] + (@device_id == 0x419 ?
        [{:type => :ram,   :start => 0x10000000, :length => 0x10000}] # STM32F42x/F43x - 64 KB CCM
        :
        [] # STM32F40x - no CCM
      )
  end
    
  class FlashController
    include Peripheral

    default_address 0x40023C00

    # Flash Key Register, 0x04
    unsigned :KEYR, 0x04

    register :SR, 0x0C do
      # Flash Status Register, 0x0C
      bool :EOP, [0x00, 0], :desc => "End of Operation"
      bool :OPERR, [0x00, 1], :desc => "Operation Error"
      bool :WPERR, [0x00, 4], :desc => "Write Protect Error"
      bool :PGAERR, [0x00, 5], :desc => "Programming Alignment Error"
      bool :PGPERR, [0x00, 6], :desc => "Programming Parallelism Error"
      bool :PGSERR, [0x00, 7], :desc => "Programming Sequence Error"
      bool :BSY, [0x02, 0], :desc => "Busy"
    end
    register :CR, 0x10 do
      # Flash Control Register, 0x10
      bool :PG, [0x00, 0], :desc => "Programming"
      bool :SER, [0x00, 1], :desc => "Sector Erase"
      bool :MER, [0x00, 2], :desc => "Mass Erase, bank 1"
      unsigned :SNB, [0x00, 6..3], :desc => "Sector Number (within bank)"
      unsigned :SNBANK, [0x00, 7], :desc => "Sector Number Bank (F42x/F43x only)"
      enum :PSIZE, [0x01, 1..0], {
        8 => 0b00,  # 1.8-2.1V
        16 => 0b01, # 2.1-2.7V
        32 => 0b10, # 2.7-3.6V
        64 => 0b11, # external Vpp only
      }
      bool :MER1, [0x01, 7], :desc => "Mass Erase, bank 2 (F42x/F43x only)"
      bool :STRT, [0x02, 0], :desc => "Start Erase"
      bool :EOPIE, [0x03, 0], :desc => "End of Operation Interrupt Enable"
      bool :ERRIE, [0x03, 1], :desc => "Error Interrupt Enable"
      bool :LOCK, [0x03, 7], :desc => "Lock"
    end
  end
  
  def wait_for_flash
    while @flash.SR.BSY
      sleep 0.01
    end
  end
  
  def unlock_flash
    Log(:stm32, 4){ "unlocking the flash" }
    if @flash.CR.LOCK
      @flash.KEYR = 0x45670123
      @flash.KEYR = 0xCDEF89AB
      if @flash.CR.LOCK
        raise RuntimeError, "Cannot unlock flash"
      end
    end
    self.wait_for_flash
    @flash.CR.PSIZE = 32 # 32 bits at a time, requires at least 2.7V
    Log(:stm32, 4){ "flash unlocked" }
  end
  
  def lock_flash
    @flash.CR.LOCK = true
  end

  def flash_op(&block)
    self.unlock_flash
    yield
    Log(:stm32, 4){ "waiting for flash transaction to be completed" }
    self.wait_for_flash
    self.lock_flash
    self.handle_flash_error
    Log(:stm32, 4){ "flash transaction completed" }
  end

  def handle_flash_error
    if @flash.SR.PGSERR
      raise RuntimeError, "Programming Sequence Error"
    end
    if @flash.SR.PGPERR
      raise RuntimeError, "Programming Parallelism Error"
    end
    if @flash.SR.PGAERR
      raise RuntimeError, "Programming Alignment Error"
    end
    if @flash.SR.WPERR
      raise RuntimeError, "Write Protect Error"
    end
  end
  
  def mass_erase
    self.flash_op do
      @flash.CR.MER = true
      if @bank2
        @flash.CR.MER1 = true
      end
      @flash.CR.STRT = true
    end
  end
  
  def sector_erase(sector_no, sector_bank)
    Log(:stm32, 3){ "erasing sector %d, bank %d" % [sector_no, sector_bank] }
    self.flash_op do
      @flash.CR.transact do |cr|
        cr.SER = true
        cr.SNB = sector_no # sector number (within bank)
        cr.SNBANK = sector_bank # sector bank number
      end
      @flash.CR.STRT = true
    end
  end
  
  def range_erase(addr, size)
    Log(:stm32, 2){ "erasing sectors for range %08x-%08x" % [addr, addr + size - 1] }
    @flash_sectors.each do |sector_addr, sector_size, sector_no, sector_bank|
      # Check if the sector overlaps the 
      if addr + size > sector_addr && addr < sector_addr + sector_size
        self.sector_erase(sector_no, sector_bank)
      else
        Log(:stm32, 3){ "omitting sector: %08x-%08x" % [sector_addr, sector_addr + sector_size - 1] }
      end
    end
  end

  def program_section(addr, data)
    if (addr & 3) != 0
      raise RuntimeError, "Misaligned programming address"
    end
    if String === data
      data = (data + "\0"*3).unpack('V*')
    end
    self.range_erase(addr, data.length * 4)
    Log(:stm32, 2){ "programming range %08x-%08x" % [addr, addr + data.length * 4 - 1] }
    self.flash_op do
      @flash.CR.PG = true
      pos = 0
      data.each do |w|
        @dap.write(addr + pos, w)
        pos += 4
      end
    end
  end
end

if $0 == __FILE__
  require 'backend-driver'
  bkend = BackendDriver.from_string(ARGV[0])
  k = STM32F4.new(bkend)
end
