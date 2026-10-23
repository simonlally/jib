# Fake bulb on 0.0.0.0:9999 for exercising the write path without touching real lamps.
# Usage: ruby Tools/mockbulb.rb [logfile]   — then add 127.0.0.1 (simulator) or this Mac's LAN IP in Jib.
# Speaks get_sysinfo, transition_light_state, the schedule service (rules fire for real, on the
# mock's own clock) and the time service (set_time moves that clock).
require "socket"; require "json"; require "securerandom"
def encrypt(str) key = 171; str.bytes.map { |b| key ^= b }.pack("C*") end
def decrypt(data) key = 171; data.bytes.map { |c| (key ^ c).tap { key = c } }.pack("C*").force_encoding("UTF-8") end
STATE = { "on_off" => 0, "mode" => "normal", "hue" => 0, "saturation" => 0, "color_temp" => 2700, "brightness" => 50 }
RULES = []                 # rule hashes as the bulb would store them
CLOCK = { "offset" => 0, "tz" => 18, "enabled" => 1 }   # offset: seconds the mock clock is ahead of real time
LOG = File.open(ARGV[0] || "mockbulb.log", "a"); LOG.sync = true
def now() Time.now + CLOCK["offset"] end
def log(line) LOG.puts "#{Time.now.strftime('%H:%M:%S.%L')} #{line}" end
def light_state
  STATE["on_off"] == 1 ? STATE.dup : { "on_off" => 0, "dft_on_state" => STATE.reject { |k, _| k == "on_off" } }
end
def apply_light(l)
  %w[on_off hue saturation color_temp brightness].each { |k| STATE[k] = l[k] if l.key?(k) && (l["on_off"] == 1 || k == "on_off") }
end
# The next enabled fixed-time rule, scanning today and the following week. Returns [rule, seconds-from-midnight].
def next_action
  t = now; today = t.hour * 60 + t.min
  (0..7).each do |ahead|
    wday = (t.wday + ahead) % 7
    due = RULES.select { |r| r["enable"] == 1 && r["stime_opt"] == 0 && r["wday"][wday] == 1 && (ahead > 0 || r["smin"] > today) }
    rule = due.min_by { |r| r["smin"] }
    return [rule, rule["smin"] * 60] if rule
  end
  nil
end
# Fire rules on the mock's clock, once per minute each.
Thread.new do
  fired = {}
  loop do
    t = now; minute = t.hour * 60 + t.min; stamp = [t.yday, minute]
    if CLOCK["enabled"] == 1
      RULES.each do |r|
        next unless r["enable"] == 1 && r["stime_opt"] == 0 && r["wday"][t.wday] == 1 && r["smin"] == minute
        next if fired[r["id"]] == stamp
        fired[r["id"]] = stamp
        apply_light(r["s_light"] || {})
        log "FIRED #{r['id']} -> #{STATE.to_json}"
      end
    end
    sleep 2
  end
end
server = TCPServer.new("0.0.0.0", 9999)
STDERR.puts "mock bulb listening on 9999"
loop do
  client = server.accept
  Thread.new(client) do |c|
    begin
      hdr = c.read(4); next unless hdr
      req = JSON.parse(decrypt(c.read(hdr.unpack1("N"))))
      log "REQ #{req.to_json}"
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
      if (s = req["smartlife.iot.common.schedule"])
        out = {}
        if s.key?("get_rules")
          out["get_rules"] = { "rule_list" => RULES, "version" => 2, "enable" => CLOCK["enabled"], "err_code" => 0 }
        end
        if (r = s["add_rule"])
          id = SecureRandom.hex(16).upcase
          RULES << r.merge("id" => id)
          out["add_rule"] = { "id" => id, "err_code" => 0 }
        end
        if (r = s["edit_rule"])
          i = RULES.index { |x| x["id"] == r["id"] }
          out["edit_rule"] = i ? (RULES[i] = r; { "err_code" => 0 }) : { "err_code" => -14, "err_msg" => "rule not found" }
        end
        if (r = s["delete_rule"])
          RULES.reject! { |x| x["id"] == r["id"] }
          out["delete_rule"] = { "err_code" => 0 }
        end
        if (r = s["set_overall_enable"])
          CLOCK["enabled"] = r["enable"]
          out["set_overall_enable"] = { "err_code" => 0 }
        end
        if s.key?("get_next_action")
          rule, secs = next_action
          out["get_next_action"] = rule ? { "type" => 1, "id" => rule["id"], "schd_time" => secs, "action" => 2,
                                            "light" => rule["s_light"], "err_code" => 0 }
                                        : { "type" => -1, "err_code" => 0 }
        end
        resp["smartlife.iot.common.schedule"] = out
      end
      if (ts = req["smartlife.iot.common.timesetting"])
        out = {}
        if ts.key?("get_time")
          t = now
          out["get_time"] = { "year" => t.year, "month" => t.month, "mday" => t.day, "hour" => t.hour,
                              "min" => t.min, "sec" => t.sec, "err_code" => 0 }
        end
        out["get_timezone"] = { "index" => CLOCK["tz"], "err_code" => 0 } if ts.key?("get_timezone")
        %w[set_time set_timezone].each do |cmd|
          next unless (p = ts[cmd])
          CLOCK["tz"] = p["index"] if p.key?("index")
          if p.key?("year")
            CLOCK["offset"] = (Time.new(p["year"], p["month"], p["mday"], p["hour"], p["min"], p["sec"]) - Time.now).round
          end
          out[cmd] = { "err_code" => 0 }
        end
        resp["smartlife.iot.common.timesetting"] = out
      end
      log "STATE #{STATE.to_json} RULES #{RULES.size} CLOCK #{CLOCK.to_json}"
      out = encrypt(resp.to_json)
      c.write([out.bytesize].pack("N") + out)
    rescue => e
      log "ERR #{e.class}: #{e.message}"
    ensure
      c.close
    end
  end
end
