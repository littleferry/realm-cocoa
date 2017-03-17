#!/usr/bin/ruby

require 'json'

def platform_for_runtime(runtime)
  runtime['identifier'].gsub(/com.apple.CoreSimulator.SimRuntime.([^-]+)-.*/, '\1')
end

def platform_for_device_type(device_type)
  case device_type['identifier']
  when /Watch/
    'watchOS'
  when /TV/
    'tvOS'
  else
    'iOS'
  end
end

def wait_for_core_simulator_service
  # Run until we get a result since switching simulator versions often causes CoreSimulatorService to throw an exception.
  while `xcrun simctl list devices`.empty?
  end
end

def running_devices(devices)
  devices.select { |device| device['state'] != 'Shutdown' }
end

def shutdown_simulator_devices(all_devices)
  # Shut down any simulators that need it.
  running_devices(all_devices).each do |device|
    puts "Shutting down simulator #{device['udid']}"
    system("xcrun simctl shutdown #{device['udid']}") or puts "    Failed to shut down simulator #{device['udid']}"
  end
end

begin

  # Kill all the current simulator processes as they may be from a different Xcode version
  print 'Killing running Simulator processes...'
  while system('pgrep -q Simulator')
    system('pkill Simulator 2>/dev/null')
    # CoreSimulatorService doesn't exit when sent SIGTERM
    system('pkill -9 Simulator 2>/dev/null')
  end
  puts ' done!'

  wait_for_core_simulator_service

  system('xcrun simctl delete unavailable') or raise 'Failed to delete unavailable simulators'

  # Shut down any running simulator devices. This may take multiple attempts if some
  # simulators are currently in the process of booting or being created.
  all_devices = []
  (0..5).each do |shutdown_attempt|
    devices_json = `xcrun simctl list devices -j`
    all_devices = JSON.parse(devices_json)['devices'].flat_map { |_, devices| devices }
    break if running_devices(all_devices).empty?

    shutdown_simulator_devices all_devices
    sleep shutdown_attempt if shutdown_attempt > 0
  end

  # Delete all simulators.
  print 'Deleting all simulators...'
  all_devices.each do |device|
    system("xcrun simctl delete #{device['udid']}") or raise "Failed to delete simulator #{device['udid']}"
  end
  puts ' done!'

  # Recreate all simulators.
  runtimes = JSON.parse(`xcrun simctl list runtimes -j`)['runtimes']
  device_types = JSON.parse(`xcrun simctl list devicetypes -j`)['devicetypes']

  runtimes_by_platform = Hash.new { |hash, key| hash[key] = [] }
  runtimes.each do |runtime|
    next unless runtime['availability'] == '(available)'
    runtimes_by_platform[platform_for_runtime(runtime)] << runtime
  end

  puts 'Creating fresh simulators...'
  device_types.each do |device_type|
    platform = platform_for_device_type(device_type)
    runtimes_by_platform[platform].each do |runtime|
      output = `xcrun simctl create '#{device_type['name']}' '#{device_type['identifier']}' '#{runtime['identifier']}' 2>&1`
      next if $? == 0

      puts "Failed to create device of type #{device_type['identifier']} with runtime #{runtime['identifier']}:"
      output.each_line do |line|
        puts "    #{line}"
      end
    end
  end
  puts 'Done!'

rescue
  system('ps auxwww')
  system('xcrun simctl list')
  raise
end
