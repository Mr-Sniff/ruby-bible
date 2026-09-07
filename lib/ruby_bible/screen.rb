module RubyBible
  module Ansi
    RESET = "\e[0m"
    BOLD = "\e[1m"
    DIM = "\e[2m"
    ITALIC = "\e[3m"
    UNDER = "\e[4m"
    REVERSE = "\e[7m"

    FG = {
      black: 30, red: 31, green: 32, yellow: 33,
      blue: 34, magenta: 35, cyan: 36, white: 37,
      gray: 90, bred: 91, bgreen: 92, byellow: 93,
      bblue: 94, bmagenta: 95, bcyan: 96, bwhite: 97,
    }.freeze

    module_function

    def fg(name)
      "\e[#{FG.fetch(name)}m"
    end

    def paint(text, *codes)
      return text if text.empty?
      codes = codes.map { |c| c.is_a?(Symbol) ? fg(c) : c }
      "#{codes.join}#{text}#{RESET}"
    end

    def strip(s)
      s.gsub(/\e\[[0-9;]*m/, "")
    end

    def visible_len(s)
      strip(s).length
    end

    # ANSI-aware cut at `w` visible chars.
    def trunc(s, w)
      out = +""
      i = 0
      vis = 0
      any = false
      len = s.length
      while i < len
        ch = s[i]
        if ch == "\e"
          j = s.index("m", i)
          break if j.nil?
          out << s[i..j]
          any = true
          i = j + 1
        else
          break if vis >= w
          out << ch
          vis += 1
          i += 1
        end
      end
      out << RESET if any
      out
    end

    # Pad (ANSI-aware) with spaces to exactly w visible columns.
    def pad(s, w)
      t = trunc(s, w)
      diff = w - visible_len(t)
      t + (diff > 0 ? (" " * diff) : "") + (s.include?("\e") ? RESET : "")
    end

    # Word-wrap plain text (no ANSI expected).
    def wrap(text, width)
      return [] if width <= 2
      lines = []
      text.split("\n", -1).each do |para|
        if para.length <= width
          lines << para
          next
        end
        words = para.split(/\s+/)
        cur = +""
        words.each do |word|
          while word.length > width
            if cur.empty?
              lines << word[0, width]
              word = word[width..]
            else
              lines << cur
              cur = +""
            end
          end
          if cur.empty?
            cur = word.dup
          elsif cur.length + 1 + word.length <= width
            cur << " " << word
          else
            lines << cur
            cur = word.dup
          end
        end
        lines << cur
      end
      lines
    end
  end

  # Pure rendering: assembles the full frame string from App state.
  # Layout: one header line, body rows built by concatenating three pane
  # cells per row, one footer line.
  class Screen
    include Ansi


    def initialize(app)
      @app = app
    end

    def frame
      a = @app
      h = a.height
      w = a.width
      body_h = [h - 2, 3].max
      w1, w2, w3 = columns(w)

      lrows = build_left(w1, body_h)
      mrows = build_middle(w2, body_h)
      rrows = build_right(w3, body_h)

      out = +"\e[0m"
      out << Ansi.pad(a.header_line, w) << "\n"
      body_h.times do |i|
        out << lrows[i] << mrows[i] << rrows[i] << "\n"
      end
      out << Ansi.pad(a.footer_line, w)
      out << help_overlay(w, h) if a.help_visible
      out << "\e[0m"
      out
    end

    # Pane widths that always sum to exactly w (so rows never wrap).
    # Minimums: objects 16, methods 18, preview 30.
    def columns(w)
      if w < 64
        w1 = 16
        w2 = 18
        w3 = [w - w1 - w2, 10].max
        return [w1, w2, w3]
      end
      w1 = [[(w * 0.22).floor, 16].max, 34].min
      w1 = [w1, w - 48].min
      w2 = [[(w * 0.26).floor, 18].max, 42].min
      w2 = [w2, w - w1 - 30].min
      w3 = w - w1 - w2
      [w1, w2, w3]
    end

    private

    def border_color(focused)
      focused ? "\e[36m" : "\e[90m"
    end

    def pane_top(w, title, focused)
      t = "─ #{title} "
      rest = w - Ansi.visible_len(t) - 2 # ┌ + t + ──… + ┐ = w
      "#{border_color(focused)}┌#{Ansi.paint(t, focused ? :bcyan : :cyan, BOLD)}#{'─' * [rest, 0].max}┐#{RESET}"
    end

    def pane_row(w, text)
      "#{Ansi.pad(text || "", w - 1)}\e[90m│\e[0m"
    end

    def pane_blank_row(w)
      "#{Ansi.pad("", w - 1)}\e[90m│\e[0m"
    end

    def pane_bottom(w, focused)
      "#{border_color(focused)}└#{'─' * (w - 2)}┘#{RESET}"
    end

    # Returns exactly `h` lines for a list pane.
    def build_list(w, h, title, focused, lines, cursor, suffix)
      rows = [pane_top(w, title + suffix, focused)]
      content_h = h - 2
      if lines.empty?
        content_h.times { rows << pane_blank_row(w) }
      else
        off = 0
        if cursor
          off = cursor - content_h + 1 if cursor >= off + content_h
          off = cursor if cursor < off
        end
        visible = lines[off, content_h] || []
        visible.each_with_index do |line, i|
          idx = off + i
          line = Ansi.paint(line, REVERSE) if cursor && idx == cursor
          rows << pane_row(w, line)
        end
        (content_h - visible.size).times { rows << pane_blank_row(w) }
      end
      rows << pane_bottom(w, focused)
      rows
    end

    def build_left(w, h)
      a = @app
      build_list(w, h, "Objects", a.focus == :objects, a.objects_lines, a.objects_cursor, "")
    end

    def build_middle(w, h)
      a = @app
      build_list(w, h, "Methods", a.focus == :methods, a.methods_lines, a.methods_cursor, "")
    end

    def build_right(w, h)
      a = @app
      content_h = h - 2
      lines = a.preview_lines
      total = lines.size
      title = +"Preview"
      unless a.preview_topic.empty?
        title << "  #{Ansi.paint(Ansi.trunc(a.preview_topic, w - 30), :bwhite, BOLD)}"
      end
      if total > content_h
        pct = (a.preview_scroll * 100.0 / (total - content_h)).round
        title << " #{Ansi.paint("(#{pct}%)", DIM)}" if a.focus == :preview
      end
      rows = [pane_top(w, title, a.focus == :preview)]
      slice = lines[a.preview_scroll, content_h] || []
      slice.each { |l| rows << pane_row(w, l) }
      (content_h - slice.size).times { rows << pane_blank_row(w) }
      rows << pane_bottom(w, a.focus == :preview)
      rows
    end

    def help_overlay(w, h)
      keys = [
        ["j / k / ↑ ↓", "move cursor (scroll in preview)"],
        ["l / ↵", "expand group · focus preview"],
        ["h", "collapse / go left"],
        ["1 2 3", "jump to Objects / Methods / Preview"],
        ["Tab / Shift-Tab", "cycle panes"],
        ["/", "filter current pane (Esc clears)"],
        ["a", "toggle inherited methods"],
        ["d / s", "jump to docs / source (preview)"],
        ["g / G", "top / end"],
        ["Ctrl-D / Ctrl-U", "half-page scroll (preview)"],
        ["?", "toggle help"],
        ["q", "quit"],
      ]
      box_w = [w - 8, 70].min
      box_h = keys.size + 4
      top = [(h - box_h) / 2, 0].max
      left = [(w - box_w) / 2, 0].max
      out = +"\e[s"
      box_h.times do |i|
        line =
          if i.zero?
            top_styled(box_w, "? ruby-bible — keybindings")
          elsif i == box_h - 1
            "\e[96m└#{'─' * (box_w - 2)}┘\e[0m"
          else
            ki = i - 1
            if ki < keys.size
              k, desc = keys[ki]
              inner = " #{Ansi.paint(k.ljust(17), :bgreen, BOLD)}#{Ansi.paint(desc, :white)}"
              mid_styled(box_w, inner)
            else
              mid_styled(box_w, "")
            end
          end
        out << "\e[#{top + i + 1};#{left + 1}H#{line}"
      end
      out << "\e[u"
      out
    end

    def top_styled(w, title)
      t = "┌─ #{Ansi.paint(title, :bcyan, BOLD)} "
      rest = w - Ansi.visible_len(t) - 1
      "\e[96m#{t}#{'─' * [rest, 0].max}┐\e[0m"
    end

    def mid_styled(w, inner)
      "\e[96m│\e[0m#{Ansi.pad(inner, w - 2)}\e[96m│\e[0m"
    end
  end
end
