#!/usr/bin/env ruby
# Kalender Tim: API + feed iCalendar (.ics) + file statis (PWA).
# Jalankan: ruby server.rb   (PORT=3000 secara default)
require 'webrick'
require 'json'
require 'securerandom'
require 'time'
require 'date'

PORT    = (ENV['PORT'] || 3000).to_i
ROOT    = __dir__
DB_FILE = ENV['DB_FILE'] || File.join(ROOT, 'data.json')
LOCK    = Mutex.new
DB      = File.exist?(DB_FILE) ? JSON.parse(File.read(DB_FILE)) : { 'teams' => {} }
CODE_CHARS = %w[A B C D E F G H J K M N P Q R S T U V W X Y Z 2 3 4 5 6 7 8 9].freeze

def save!
  File.write("#{DB_FILE}.tmp", JSON.generate(DB))
  File.rename("#{DB_FILE}.tmp", DB_FILE)
end

def new_code
  loop do
    c = Array.new(6) { CODE_CHARS[SecureRandom.random_number(CODE_CHARS.size)] }.join
    return c unless DB['teams'].key?(c)
  end
end

def team_by_code(code); DB['teams'][code.to_s.upcase]; end
def team_by_token(tok); DB['teams'].values.find { |t| t['feedToken'] == tok }; end

DATE_RE = /\A\d{4}-\d{2}-\d{2}\z/

# Mengembalikan [data_bersih, nil] atau [nil, pesan_error]
def clean_event(b)
  title = b['title'].to_s.strip
  return [nil, 'Judul wajib diisi'] if title.empty?
  return [nil, 'Judul terlalu panjang'] if title.size > 200

  all_day = b['allDay'] == true
  begin
    if all_day
      return [nil, 'Format tanggal salah'] unless b['start'].to_s =~ DATE_RE && b['end'].to_s =~ DATE_RE
      s = Date.strptime(b['start'], '%Y-%m-%d')
      e = Date.strptime(b['end'], '%Y-%m-%d')
      start_v = s.to_s
      end_v = e.to_s
    else
      s = Time.iso8601(b['start'].to_s)
      e = Time.iso8601(b['end'].to_s)
      start_v = s.utc.iso8601
      end_v = e.utc.iso8601
    end
  rescue ArgumentError
    return [nil, 'Format tanggal/waktu salah']
  end
  return [nil, 'Waktu selesai sebelum waktu mulai'] if e < s

  [{
    'title' => title, 'allDay' => all_day, 'start' => start_v, 'end' => end_v,
    'location' => b['location'].to_s.strip[0, 200],
    'notes' => b['notes'].to_s.strip[0, 2000],
    'assignee' => b['assignee'].to_s.strip[0, 80],
    'by' => b['by'].to_s.strip[0, 80]
  }, nil]
end

# ---------- iCalendar ----------
def ics_esc(s)
  s.to_s.gsub(/[\\;,]/) { "\\#{$&}" }.gsub(/\r?\n/, '\\n')
end

def ics_fold(line)
  out = []
  cur = +''
  line.each_char do |c|
    if cur.bytesize + c.bytesize > (out.empty? ? 75 : 74)
      out << cur
      cur = +''
    end
    cur << c
  end
  out << cur
  out.join("\r\n ")
end

def ics_utc(iso); Time.iso8601(iso).utc.strftime('%Y%m%dT%H%M%SZ'); end

def build_ics(team)
  lines = [
    'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Kalender Tim//ID', 'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH', "X-WR-CALNAME:#{ics_esc(team['name'])}",
    'REFRESH-INTERVAL;VALUE=DURATION:PT15M', 'X-PUBLISHED-TTL:PT15M'
  ]
  team['events'].each do |ev|
    lines << 'BEGIN:VEVENT'
    lines << "UID:#{ev['id']}@kalender-tim"
    lines << "DTSTAMP:#{ics_utc(ev['updatedAt'])}"
    lines << "LAST-MODIFIED:#{ics_utc(ev['updatedAt'])}"
    lines << "SEQUENCE:#{ev['seq'].to_i}"
    if ev['allDay']
      lines << "DTSTART;VALUE=DATE:#{ev['start'].delete('-')}"
      lines << "DTEND;VALUE=DATE:#{(Date.parse(ev['end']) + 1).strftime('%Y%m%d')}"
    else
      lines << "DTSTART:#{ics_utc(ev['start'])}"
      lines << "DTEND:#{ics_utc(ev['end'])}"
    end
    lines << "SUMMARY:#{ics_esc(ev['title'])}"
    lines << "LOCATION:#{ics_esc(ev['location'])}" unless ev['location'].to_s.empty?
    desc = []
    desc << "Penanggung jawab: #{ev['assignee']}" unless ev['assignee'].to_s.empty?
    desc << ev['notes'] unless ev['notes'].to_s.empty?
    lines << "DESCRIPTION:#{ics_esc(desc.join("\n"))}" unless desc.empty?
    lines << 'END:VEVENT'
  end
  lines << 'END:VCALENDAR'
  lines.map { |l| ics_fold(l) }.join("\r\n") + "\r\n"
end

# ---------- Server ----------
mime = WEBrick::HTTPUtils::DefaultMimeTypes.merge('webmanifest' => 'application/manifest+json', 'svg' => 'image/svg+xml')
server = WEBrick::HTTPServer.new(
  Port: PORT, BindAddress: '0.0.0.0', AccessLog: [], MimeTypes: mime,
  DocumentRoot: File.join(ROOT, 'public'), Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
)

def reply(res, status, obj)
  res.status = status
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Cache-Control'] = 'no-store'
  res.body = JSON.generate(obj)
end

server.mount_proc('/cal/') do |req, res|
  tok = File.basename(req.path, '.ics')
  team = LOCK.synchronize { team_by_token(tok) }
  if team.nil?
    res.status = 404
    res.body = 'Kalender tidak ditemukan'
  else
    res['Content-Type'] = 'text/calendar; charset=utf-8'
    res['Cache-Control'] = 'no-cache'
    res['Content-Disposition'] = 'inline; filename="kalender-tim.ics"'
    res.body = LOCK.synchronize { build_ics(team) }
  end
end

server.mount_proc('/api/') do |req, res|
  seg = req.path.sub(%r{\A/api/}, '').split('/')
  body = {}
  unless req.body.to_s.empty?
    if req.body.bytesize > 100_000
      next reply(res, 413, error: 'Data terlalu besar')
    end
    begin
      body = JSON.parse(req.body)
      raise JSON::ParserError unless body.is_a?(Hash)
    rescue JSON::ParserError
      next reply(res, 400, error: 'JSON tidak valid')
    end
  end

  LOCK.synchronize do
    next reply(res, 404, error: 'Tidak ditemukan') unless seg[0] == 'teams'

    # POST /api/teams
    if seg.size == 1 && req.request_method == 'POST'
      name = body['name'].to_s.strip
      next reply(res, 422, error: 'Nama tim wajib diisi') if name.empty? || name.size > 80
      t = { 'code' => new_code, 'name' => name, 'feedToken' => SecureRandom.hex(16),
            'createdAt' => Time.now.utc.iso8601, 'events' => [] }
      DB['teams'][t['code']] = t
      save!
      next reply(res, 201, t.reject { |k, _| k == 'events' })
    end

    team = team_by_code(seg[1])
    next reply(res, 404, error: 'Kode tim tidak ditemukan') unless team

    # GET /api/teams/:code
    if seg.size == 2 && req.request_method == 'GET'
      next reply(res, 200, team.reject { |k, _| k == 'events' })
    end

    next reply(res, 404, error: 'Tidak ditemukan') unless seg[2] == 'events'

    if seg.size == 3
      case req.request_method
      when 'GET'
        next reply(res, 200, team['events'].sort_by { |e| e['start'] })
      when 'POST'
        data, err = clean_event(body)
        next reply(res, 422, error: err) if err
        now = Time.now.utc.iso8601
        ev = data.merge('id' => SecureRandom.hex(8), 'seq' => 0, 'createdAt' => now, 'updatedAt' => now)
        team['events'] << ev
        save!
        next reply(res, 201, ev)
      end
    elsif seg.size == 4
      ev = team['events'].find { |e| e['id'] == seg[3] }
      next reply(res, 404, error: 'Kegiatan tidak ditemukan') unless ev
      case req.request_method
      when 'PUT'
        data, err = clean_event(body)
        next reply(res, 422, error: err) if err
        ev.merge!(data)
        ev['seq'] = ev['seq'].to_i + 1
        ev['updatedAt'] = Time.now.utc.iso8601
        save!
        next reply(res, 200, ev)
      when 'DELETE'
        team['events'].delete(ev)
        save!
        next reply(res, 200, ok: true)
      end
    end
    reply(res, 405, error: 'Metode tidak didukung')
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
puts "Kalender Tim berjalan di http://localhost:#{PORT}"
server.start
