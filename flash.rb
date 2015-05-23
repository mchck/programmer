$: << File.realpath('..', __FILE__)

require 'device'
require 'backend-driver'
require 'optparse'
require 'ostruct'

options = {}
OptionParser.new do |opts|
  opts.banner = 'Usage: flash [options] file1 offset1 [file2 offset2 ...]'

  options[:backend] = BackendDriver.options(opts)

  opts.on('--mass-erase', 'Mass erase') do |v|
    options[:mass_erase] = v
  end
end.parse!

def readbins
  ret = []

  pos = 0
  while ARGV.count > pos
    fw = OpenStruct.new({
      name: ARGV[pos],
      data: File.read(ARGV[pos], :mode => 'rb'),
      address: Integer(ARGV[pos + 1]),
    })
    pos += 2
    ret << fw
  end

  ret
end

bins = readbins

$stderr.puts "Attaching debugger..."
k = Device.detect(BackendDriver.from_opts(options[:backend]))
$stderr.puts "done."

#k.program do
k.halt_core!
begin
  if options[:mass_erase]
    $stderr.puts "Mass erasing chip..."
    k.mass_erase
    $stderr.puts "done."
  end

  bins.each do |fw|
    $stderr.puts "Programming %s, %d bytes to address %#x..." % [fw.name, fw.data.bytesize, fw.address]
    k.program_section(fw.address, fw.data) do |address, i, total|
      $stderr.puts "programming %#x, %d of %d" % [address, i, total]
    end
    $stderr.puts "done with %s." % fw.name
  end

  $stderr.puts "finishing..."
end
k.reset_system!
k.disable_debug!
k.continue!
$stderr.puts "done."
