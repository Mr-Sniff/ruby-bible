module RubyBible
  # Reads keys and mouse events from a raw console, mapping escape
  # sequences, Windows scan codes and SGR mouse reports into symbols.
  class Input
    SEQ = {
      "\e[A" => :up, "\e[B" => :down, "\e[C" => :right, "\e[D" => :left,
      "\eOA" => :up, "\eOB" => :down, "\eOC" => :right, "\eOD" => :left,
      "\e[H" => :home, "\e[F" => :end, "\e[1~" => :home, "\e[4~" => :end,
      "\e[5~" => :pgup, "\e[6~" => :pgdn, "\e[3~" => :del,
      "\e[Z" => :stab,
    }.freeze

    # Windows delivers arrow/nav keys as a 0x00/0xE0 prefix + scan code.
    SCAN = {
      0x48 => :up, 0x50 => :down, 0x4B => :left, 0x4D => :right,
      0x49 => :pgup, 0x51 => :pgdn, 0x47 => :home, 0x4F => :end,
      0x53 => :del,
    }.freeze

    MOUSE_ENABLE  = "\e[?1002h\e[?1006h".freeze
    MOUSE_DISABLE = "\e[?1002l\e[?1006l".freeze

    MOUSE_PREFIX = "\e[<".b

    def initialize(io)
      @io = io
      @pending = []
      @chunks = []
      @mutex = Mutex.new
      @reader = Thread.new { reader_loop } if Terminal.windows?
    end

    # Next logical key/event, or nil after `timeout` seconds, or :eof.
    def next_key(timeout)
      return threaded_next(timeout) if @reader
      select_next(timeout)
    end

    private

    # ---- readers ---------------------------------------------------

    def reader_loop
      loop do
        chunk = @io.readpartial(4096)
        break if chunk.nil?
        @mutex.synchronize { @chunks << chunk }
      end
    rescue StandardError
      nil
    end

    def select_next(timeout)
      loop do
        return @pending.shift if @pending.any?
        r = IO.select([@io], nil, nil, timeout)
        return nil unless r
        chunk = @io.read_nonblock(4096, exception: false)
        return :eof if chunk.nil?
        return nil if chunk == :wait_readable || chunk.empty?
        parse(chunk)
      end
    end

    def threaded_next(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return @pending.shift if @pending.any?
        if (buf = drain)
          parse(buf)
          next
        end
        return :eof if !@reader.alive? && @pending.empty?
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end
    end

    def drain
      @mutex.synchronize do
        next nil if @chunks.empty?
        s = @chunks.join.b
        @chunks.clear
        s
      end
    end

    # Grab extra bytes for a partial escape sequence, or nil when none
    # arrive quickly. The threaded reader drains queued chunks; the select
    # reader polls the fd directly.
    def grab_more(limit)
      if @reader
        more = drain
        unless more
          sleep 0.01
          more = drain
        end
        more
      elsif @io.respond_to?(:wait_readable) && @io.wait_readable(0.02)
        m = @io.read_nonblock(limit, exception: false)
        m.is_a?(String) && !m.empty? ? m.b : nil
      end
    end

    # ---- parser ----------------------------------------------------

    def parse(chunk)
      buf = chunk.b
      until buf.empty?
        if buf.start_with?("\x00".b, "\xE0".b)
          scan = buf.getbyte(1)
          sym = scan && SCAN[scan]
          if sym
            @pending << sym
            buf = rest(buf, 2)
          elsif scan.nil? && buf.bytesize < 2 && (more = grab_more(1))
            buf += more
          else
            buf = rest(buf, 1)
          end
        elsif buf.start_with?("\e".b)
          t = parse_escape(buf)
          case t
          in [:sym, sym, rest_buf]  then @pending << sym; buf = rest_buf
          in [:mouse, ev, rest_buf] then @pending << ev;  buf = rest_buf
          in [:skip, rest_buf]      then buf = rest_buf
          in :more                  then buf = append_or_esc(buf)
          else                           buf = emit_esc(buf)
          end
        else
          @pending << self.class.char(buf.byteslice(0, 1))
          buf = rest(buf, 1)
        end
      end
    end

    def append_or_esc(buf)
      if (more = grab_more(64))
        buf + more
      else
        emit_esc(buf)
      end
    end

    def emit_esc(buf)
      @pending << :esc
      rest(buf, 1)
    end

    def rest(buf, n)
      buf.byteslice(n, buf.bytesize - n) || "".b
    end

    # Classify a buffer starting with "\e" into [:sym, sym, rest],
    # [:mouse, event, rest], :more (need bytes), [:skip, rest] (malformed),
    # or nil (treat as :esc).
    def parse_escape(buf)
      if buf.start_with?(MOUSE_PREFIX)
        r = consume_mouse(buf)
        return :more if r.nil?
        return [:skip, r[1]] if r[0].nil?
        return [:mouse, r[0], r[1]]
      end
      seq = SEQ.keys.find { |s| buf.start_with?(s.b) }
      return [:sym, SEQ[seq], rest(buf, seq.bytesize)] if seq
      if buf.bytesize < 4 && (SEQ.keys.any? { |s| s.b.start_with?(buf) } || buf.start_with?(MOUSE_PREFIX))
        :more
      end
    end

    # SGR 1006: "\e[<b;c;rM" (press) / "\e[<b;c;rm" (release).
    def consume_mouse(buf)
      return unless buf.start_with?(MOUSE_PREFIX)
      i = [buf.index("m"), buf.index("M")].compact.min
      return if i.nil?
      parts = buf.byteslice(3, i - 3).split(";")
      press = buf.getbyte(i) == 0x4D
      if parts.size >= 3
        [[:mouse, parts[0].to_i, parts[1].to_i, parts[2].to_i, press], rest(buf, i + 1)]
      else
        [nil, rest(buf, i + 1)]
      end
    end

    def self.char(byte)
      c = byte.to_s.force_encoding(Encoding::UTF_8)
      case c
      when "\r", "\n" then :enter
      when "\t" then :tab
      when "\e" then :esc
      when "\x7f", "\b" then :backspace
      when "\x03" then :"C-c"
      when "\x04" then :"C-d"
      when "\x15" then :"C-u"
      when "\x01" then :"C-a"
      when "\x05" then :"C-e"
      else c
      end
    end
  end
end
