# Fake bulb on 0.0.0.0:9999 for exercising the write path without touching real lamps.
# Usage: ruby Tools/mockbulb.rb [logfile]   — then add 127.0.0.1 (simulator) or this Mac's LAN IP in Jib.
require "socket"; require "json"
def encrypt(str) key = 171; str.bytes.map { |b| key ^= b }.pack("C*") end
def decrypt(data) key = 171; data.bytes.map { |c| (key ^ c).tap { key = c } }.pack("C*").force_encoding("UTF-8") end
STATE = { "on_off" => 0, "mode" => "normal", "hue" => 0, "saturation" => 0, "color_temp" => 2700, "brightness" => 50 }
LOG = File.open(ARGV[0] || "mockbulb.log", "a"); LOG.sync = true
def light_state
  STATE["on_off"] == 1 ? STATE.dup : { "on_off" => 0, "dft_on_state" => STATE.reject { |k, _| k == "on_off" } }
end
server = TCPServer.new("0.0.0.0", 9999)
STDERR.puts "mock bulb listening on 9999"
loop do
  client = server.accept
  Thread.new(client) do |c|
    begin
      hdr = c.read(4); next unless hdr
      req = JSON.parse(decrypt(c.read(hdr.unpack1("N"))))
      LOG.puts "#{Time.now.strftime('%H:%M:%S.%L')} REQ #{req.to_json}"
      resp = {}
      if req.dig("system", "get_sysinfo")
        resp["system"] = { "get_sysinfo" => {
          "sw_ver" => "mock 1.0", "hw_ver" => "2.0", "model" => "KL125(US)", "rssi" => -40,
          "alias" => "Mock Bulb", "mic_type" => "IOT.SMARTBULB",
          "is_dimmable" => 1, "is_color" => 1, "is_variable_color_temp" => 1,
          "light_state" => light_state,
          "preferred_state" => [
            { "index" => 0, "hue" => 0, "saturation" => 0, "color_temp" => 2700, "brightness" => 50 },
            { "index" => 1, "hue" => 0, "saturation" => 100, "color_temp" => 2700, "brightness" => 14 },
            { "index" => 2, "hue" => 120, "saturation" => 100, "color_temp" => 0, "brightness" => 100 },
            { "index" => 3, "hue" => 240, "saturation" => 100, "color_temp" => 0, "brightness" => 100 } ],
          "err_code" => 0 } }
      end
      if (t = req.dig("smartlife.iot.smartbulb.lightingservice", "transition_light_state"))
        %w[on_off hue saturation color_temp brightness].each { |k| STATE[k] = t[k] if t.key?(k) }
        resp["smartlife.iot.smartbulb.lightingservice"] = { "transition_light_state" => light_state.merge("err_code" => 0) }
      end
      LOG.puts "#{Time.now.strftime('%H:%M:%S.%L')} STATE #{STATE.to_json}"
      out = encrypt(resp.to_json)
      c.write([out.bytesize].pack("N") + out)
    rescue => e
      LOG.puts "ERR #{e.class}: #{e.message}"
    ensure
      c.close
    end
  end
end
