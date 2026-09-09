require "io/console"
require "set"

module RubyBible
  class App
    include Ansi

    FOCUSES = %i[objects methods preview].freeze

    attr_reader :height, :width, :focus, :help_visible, :show_inherited
    attr_reader :preview_scroll, :preview_topic
    attr_reader :objects_lines, :objects_cursor, :methods_lines, :methods_cursor
    attr_accessor :dirty

    def initialize(opts = {})
      @stdout = $stdout
      @stdin = opts.fetch(:stdin, $stdin)
      @key_source = opts[:keys] # e.g. "jjlq" for scripted runs
      @once = opts.fetch(:once, false)
      @focus = :objects
      @help_visible = false
      @show_inherited = false
      @objects_filter = nil
      @methods_filter = nil
      @search_active = false
      @search_buffer = +""
      @search_pane = nil
      @preview_lines = []
      @preview_topic = ""
      @preview_scroll = 0
      @anchors = {}
      @doc_state = nil
      @preview_key = nil
      @dirty = true
      @running = true
      @expanded = Set.new(["Core"])

      @objects_cursor = 0
      update_geometry
      refresh_objects
      first_entry = @objects_rows.index { |r| r[:type] == :entry }
      @objects_cursor = first_entry || 0
      select_target(selected_entry&.target)
      @prefetch_thread = nil
      Thread.new { Docs.warmup; @dirty = true } unless @once || @key_source
      Docs.warmup if @once || @key_source
    end

    # ---- geometry ----------------------------------------------------

    def update_geometry
      @height, @width =
        begin
          @stdout.winsize
        rescue StandardError
          [40, 120]
        end
      @height = 40 if @height.to_i < 5
      @width = 120 if @width.to_i < 20
    end

    def preview_width
      Screen.new(self).columns(@width)[2] - 2
    end

    def content_height
      [@height - 4, 1].max
    end

    # ---- objects pane -------------------------------------------------

    def refresh_objects
      rows = []
      if @objects_filter
        q = @objects_filter.downcase
        seen = {}
        (Registry.groups.flat_map { |g, es| es.map { |e| [g, e] } } +
         Registry.everything.map { |e| ["all", e] }).each do |group, e|
          next unless e.label.downcase.include?(q)
          next if seen[e.target.object_id]
          seen[e.target.object_id] = true
          rows << { type: :entry, group: group, entry: e }
        end
      else
        list = Registry.groups + [["All loaded", Registry.everything]]
        list.each do |group, es|
          open = @expanded.include?(group)
          rows << { type: :group, group: group,
                    label: "#{open ? "▾" : "▸"} #{group} (#{es.size})" }
          if open
            es.each do |e|
              rows << { type: :entry, group: group, entry: e }
            end
          end
        end
      end
      if @objects_filter && rows.empty?
        rows << { type: :empty }
      end
      @objects_rows = rows
      @objects_lines = rows.map { |r| style_object_row(r) }
      @objects_cursor = @objects_cursor.clamp(0, [rows.size - 1, 0].max)
    end

    def style_object_row(r)
      if r[:type] == :group
        Ansi.paint(r[:label], :bcyan, BOLD)
      elsif r[:type] == :empty
        Ansi.paint("  · no matches", DIM, ITALIC)
      else
        e = r[:entry]
        color = { class: :green, module: :yellow, object: :magenta }.fetch(e.kind, :white)
        base = "  #{Ansi.paint(Registry.kind_tag(e.kind), color, BOLD)} #{e.label}"
        base << " #{Ansi.paint("· #{r[:group]}", DIM)}" if @objects_filter
        base
      end
    end

    def selected_entry
      row = @objects_rows[@objects_cursor]
      row && row[:type] == :entry ? row[:entry] : nil
    end

    # ---- methods pane --------------------------------------------------

    def rebuild_methods(keep_name = nil)
      target = selected_entry&.target
      rows = []
      if target
        if @show_inherited && target.is_a?(Module)
          inst, sing = Introspect.inherited_method_groups(target)
          inst.each do |owner, refs|
            rows << { type: :section, title: "── #{owner.name} ──" }
            refs.each { |ref| rows << { type: :method, ref: ref } }
          end
          sing.each do |owner_label, refs|
            rows << { type: :section, title: "── #{owner_label} ──" }
            refs.each { |ref| rows << { type: :method, ref: ref } }
          end
        else
          own = Introspect.own_methods(target)
          unless own[:instance].empty?
            rows << { type: :section, title: "── instance (#{own[:instance].size}) ──" }
            own[:instance].each { |ref| rows << { type: :method, ref: ref } }
          end
          unless own[:singleton].empty?
            rows << { type: :section, title: "── singleton (#{own[:singleton].size}) ──" }
            own[:singleton].each { |ref| rows << { type: :method, ref: ref } }
          end
        end
      end
      if @methods_filter
        rows = rows.select { |r| r[:type] != :method || r[:ref].name.to_s.include?(@methods_filter) }
        rows = drop_empty_sections(rows)
      end
      rows << { type: :section,
                title: @methods_filter && rows.empty? ? "── no matches ──" : "── no own methods · press a for inherited ──" } if rows.empty? && target
      @method_rows = rows
      @methods_lines = rows.map { |r| style_method_row(r) }
      @methods_cursor =
        if keep_name
          idx = rows.index { |r| r[:type] == :method && r[:ref].name.to_s == keep_name }
          idx || first_method_index(rows)
        else
          first_method_index(rows)
        end || 0
    end

    def drop_empty_sections(rows)
      out = []
      rows.each_with_index do |r, i|
        if r[:type] == :section
          nxt = rows[(i + 1)..]
          next unless nxt && nxt.first && nxt.first[:type] == :method
        end
        out << r
      end
      out
    end

    def first_method_index(rows)
      rows.index { |r| r[:type] == :method } || 0
    end

    def style_method_row(r)
      if r[:type] == :section
        Ansi.paint(r[:title], :gray, BOLD)
      else
        ref = r[:ref]
        dot = ref.singleton ? Ansi.paint(".", :bcyan) : ""
        vis = Introspect.visibility(ref)
        suffix =
          if vis == :private then Ansi.paint(" (private)", DIM, ITALIC)
          elsif vis == :protected then Ansi.paint(" (protected)", DIM, ITALIC)
          else ""
          end
        "  #{dot}#{ref.name}#{suffix}"
      end
    end

    def selected_method
      row = @method_rows && @method_rows[@methods_cursor]
      row && row[:type] == :method ? row[:ref] : nil
    end

    # ---- selection flow -------------------------------------------------

    def select_target(target)
      @target = target
      rebuild_methods
      @preview_scroll = 0
      @preview_key = nil
      request_doc
      prefetch_docs
      @dirty = true
    end

    def request_doc
      key = doc_key
      @doc_state = { key: key, ready: false, text: nil, topic: nil }
      t =
        if selected_method
          ref = selected_method
          Thread.new do
            text, topic = Docs.for_method(ref)
            finish_doc(key, text, topic)
          end
        elsif @target
          target = @target
          name = target.is_a?(Module) ? target.name : target.to_s
          Thread.new do
            text, = Docs.for_class(target)
            finish_doc(key, text, name)
          end
        end
      t.report_on_exception = false if t
    end

    # Preload documentation for every method of the current target so
    # scrolling through the Methods pane never waits on a lookup.
    def prefetch_docs
      tgt = @target
      return if tgt.nil?
      rows = @method_rows.select { |r| r[:type] == :method }
      return if rows.empty? || rows.size > 250
      Thread.new do
        rows.each do |r|
          break if @target != tgt
          Docs.for_method(r[:ref])
        end
      end
    end

    def finish_doc(key, text, topic)
      LOCK.synchronize do
        @doc_state = { key: key, ready: true, text: text, topic: topic }
      end
      @dirty = true
    end

    LOCK = Mutex.new

    def doc_key
      if (ref = selected_method)
        "m:#{ref.target.object_id}:#{ref.singleton}:#{ref.name}"
      elsif @target
        "c:#{@target.object_id}"
      else
        "none"
      end
    end

    def doc
      @doc_state if @doc_state && @doc_state[:key] == doc_key
    end

    # ---- preview ---------------------------------------------------------

    def update_preview
      pw = preview_width
      key = [doc_key, pw, @show_inherited, @methods_filter, selected_method&.name,
             @target, doc&.[](:ready)]
      return if @preview_key == key
      @preview_key = key
      @preview_topic =
        if (ref = selected_method)
          owner = ref.doc_owner || (ref.target.is_a?(Module) ? ref.target.name : Introspect.pretty_owner(ref))
          "#{owner}#{ref.singleton ? "." : "#"}#{ref.name}"
        elsif @target
          @target.is_a?(Module) ? @target.name : @target.to_s
        else
          ""
        end
      @preview_lines =
        if (ref = selected_method)
          build_method_preview(ref, pw)
        elsif @target
          build_class_preview(@target, pw)
        else
          build_welcome(pw)
        end
      clamp_scroll
    end

    def preview_lines
      update_preview
      @preview_lines
    end

    def clamp_scroll
      max = [@preview_lines.size - content_height, 0].max
      @preview_scroll = @preview_scroll.clamp(0, max)
    end

    def section_line(title, pw)
      t = "─ #{title} "
      Ansi.paint(t + "─" * [pw - t.length - 1, 0].max, :cyan, BOLD)
    end

    def build_method_preview(ref, pw)
      lines = []
      lines << Ansi.paint(Introspect.signature(ref), :bwhite, BOLD)
      vis = Introspect.visibility(ref)
      owner = ref.doc_owner || (ref.target.is_a?(Module) ? ref.target.name : Introspect.pretty_owner(ref))
      lines << Ansi.paint("owner: #{owner} · #{vis} · #{Introspect.arity_str(ref)}", DIM)
      lines << Ansi.paint("defined: #{Introspect.location(ref)}", DIM)
      lines << ""
      lines << section_line("docs (ri)", pw)
      docs_idx = lines.size - 1
      d = doc
      if d && d[:ready]
        if d[:text]
          lines.concat(render_docs(d[:text], pw))
        else
          lines << Ansi.paint("ⓘ no ri documentation found for this method", :byellow)
          lines << Ansi.paint("⚠ #{Docs.install_hint}", :byellow) if Docs.install_hint
        end
      else
        lines << Ansi.paint("loading docs…", DIM)
      end
      lines << ""
      lines << section_line("source", pw)
      src_idx = lines.size - 1
      src = Introspect.source(ref)
      if src
        src.each_line { |l| lines << highlight_ruby(l.chomp) }
      else
        lines << Ansi.paint("ⓘ implemented in C — no Ruby source available; see docs above", DIM)
      end
      @anchors = { docs: docs_idx, source: src_idx }
      lines
    end

    def build_class_preview(target, pw)
      lines = []
      kind = target.is_a?(Class) ? "class" : (target.is_a?(Module) ? "module" : "object")
      lines << Ansi.paint("#{target.is_a?(Module) ? target.name : target.to_s}  (#{kind})", :bwhite, BOLD)
      if target.is_a?(Module)
        if target.is_a?(Class) && target.superclass
          lines << Ansi.paint("superclass: #{target.superclass.name}", DIM)
        end
        own = Introspect.own_methods(target)
        lines << Ansi.paint("own methods: #{own[:instance].size} instance · #{own[:singleton].size} singleton", DIM)
        lines << ""
        lines << section_line("ancestors", pw)
        anc = "ancestors: #{target.ancestors.map { |a| a.name || a.to_s }.join(' < ')}"
        Ansi.wrap(anc, pw).each { |w| lines << Ansi.paint(w, DIM) }
        lines << ""
      end
      lines << section_line("docs (ri)", pw)
      docs_idx = lines.size - 1
      d = doc
      if d && d[:ready]
        if d[:text]
          lines.concat(render_docs(d[:text], pw))
        else
          lines << Ansi.paint("ⓘ no ri documentation found", :byellow)
          lines << Ansi.paint("⚠ #{Docs.install_hint}", :byellow) if Docs.install_hint
        end
      else
        lines << Ansi.paint("loading docs…", DIM)
      end
      @anchors = { docs: docs_idx }
      lines
    end

    def build_welcome(pw)
      art = <<~ART
        ◆  r u b y - b i b l e
        A yazi-style browser for Ruby's objects, methods,
        source code and documentation.

        Everything you read is pulled live from the running
        interpreter and the installed ri documentation.

        j/k   browse objects     l    open
        /     filter             ?    all keys
      ART
      lines = art.split("\n").map { |l| Ansi.paint(l, :bcyan) }
      lines << ""
      if Docs.install_hint
        lines << Ansi.paint("⚠ #{Docs.install_hint}", :byellow)
        lines << ""
      end
      lines
    end

    # docs text is markdown-ish from ri; reflow paragraphs, style, wrap
    def render_docs(text, pw)
      out = []
      in_code = false
      para = +""
      flush = lambda do
        if para.strip.empty?
          para = +""
        else
          Ansi.wrap(para.strip, pw).each { |w| out << Ansi.paint(w, :white) }
          para = +""
        end
      end
      text.each_line do |raw|
        line = raw.chomp
        if line.start_with?("```")
          flush.call
          in_code = !in_code
          next
        end
        if in_code || line.start_with?("    ", "\t")
          flush.call
          out << Ansi.paint(line.sub(/\A(\t| {4})/, "  "), :green)
        elsif line =~ /\A-{3,}\s*\z/
          flush.call
        elsif (m = line.match(/\A\#{1,6}\s+(.*)\z/))
          flush.call
          Ansi.wrap(m[1], pw - 2).each { |w| out << Ansi.paint(w, :bcyan, BOLD) }
        elsif line.start_with?("- ", "* ")
          flush.call
          Ansi.wrap(line, pw - 2).each do |w|
            out << (w.start_with?("- ", "* ") ? Ansi.paint(w, :byellow) : Ansi.paint(w, :white))
          end
        elsif line.strip.empty?
          flush.call
          out << ""
        else
          para << " " unless para.empty?
          para << line.strip
        end
      end
      flush.call
      out
    end

    KEYWORDS = %w[
      def end if elsif else unless while until for do begin rescue ensure
      case when class module return yield self nil true false and or not
      raise super attr_reader attr_writer attr_accessor require
      require_relative include extend private protected public lambda proc
      then next break defined?
    ].join("|").freeze

    TOKEN = /
      (?<comment>\#.*\z) |
      (?<str>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*') |
      (?<kw>\b(?:#{KEYWORDS})\b) |
      (?<sym>:[a-zA-Z_]\w*[?!=]?) |
      (?<num>\b\d[\d_]*(?:\.\d+)?\b) |
      (?<const>\b[A-Z][A-Za-z0-9_]*\b) |
      (?<ivar>[@]{1,2}[a-z_]\w*)
    /x.freeze

    def highlight_ruby(line)
      line.gsub(TOKEN) do
        m = Regexp.last_match
        case
        when m[:comment] then Ansi.paint(m[0], :green)
        when m[:str] then Ansi.paint(m[0], :byellow)
        when m[:kw] then Ansi.paint(m[0], :bcyan, BOLD)
        when m[:sym] then Ansi.paint(m[0], :bgreen)
        when m[:num] then Ansi.paint(m[0], :bmagenta)
        when m[:const] then Ansi.paint(m[0], :bblue)
        when m[:ivar] then Ansi.paint(m[0], :bred)
        else m[0]
        end
      end
    end

    # ---- header/footer ------------------------------------------------------

    def breadcrumb
      parts = []
      parts << selected_entry.label if selected_entry
      if (ref = selected_method)
        parts << "#{ref.singleton ? "." : "#"}#{ref.name}"
      end
      parts.join(" ")
    end

    def docs_status_line
      return Ansi.paint("checking docs…", DIM) unless Docs.warmed?
      return Ansi.paint("docs: core + gems", :gray) if Docs.core_docs?
      Ansi.paint("core docs missing", :byellow)
    end

    def header_line
      left = " #{Ansi.paint("◆ ruby-bible", :bcyan, BOLD)}"
      crumb = breadcrumb
      left << " #{Ansi.paint(Ansi.trunc(crumb, 40), :bwhite, BOLD)}" unless crumb.empty?
      status = docs_status_line
      gap = @width - Ansi.visible_len(left) - Ansi.visible_len(status) - 1
      left + (" " * [gap, 1].max) + status
    end

    def footer_line
      if @search_active
        return Ansi.paint(
          " /#{@search_pane} search: #{@search_buffer}█  (↑↓ navigate · ↵ keep · Esc cancel)",
          :byellow, BOLD
        )
      end
      hints =
        case @focus
        when :objects
          "j/k move · ↵/l open · h collapse · / filter/clear · 1/2/3 panes · ? help · q quit"
        when :methods
          "j/k move · ↵/l preview · a inherited:#{@show_inherited ? "on" : "off"} · / filter/clear · ? help · q quit"
        else
          "j/k scroll · d docs · s source · g/G top/end · h back · ? help · q quit"
        end
      Ansi.paint(hints, DIM)
    end

    # ---- key handling ---------------------------------------------------------

    def handle_key(k)
      if @help_visible
        @help_visible = false
        @dirty = true
        return
      end
      if @search_active
        handle_search_key(k)
        return
      end
      case k
      when "q", :"C-c"
        @running = false
      when "?"
        @help_visible = true
        @dirty = true
      when :tab
        cycle_focus(1)
      when :stab
        cycle_focus(-1)
      when "1", "2", "3"
        @focus = FOCUSES[k.to_i - 1]
        @dirty = true
      when "h", :left
        move_left
      when "l", :right
        move_right
      when "/"
        toggle_search
      when :esc
        clear_filters
      when :up, "k"
        move_cursor(-1)
      when :down, "j"
        move_cursor(1)
      when :pgup
        page_move(-1)
      when :pgdn
        page_move(1)
      when "g", :home
        jump_end(-1)
      when "G", :end
        jump_end(1)
      when :enter
        activate
      when "a"
        toggle_inherited
      when "d"
        jump_anchor(:docs)
      when "s"
        jump_anchor(:source)
      when :"C-u"
        half_page(-1)
      when :"C-d"
        half_page(1)
      end
    end

    def cycle_focus(dir)
      i = FOCUSES.index(@focus)
      @focus = FOCUSES[(i + dir) % FOCUSES.size]
      @dirty = true
    end

    def move_focus(dir)
      i = FOCUSES.index(@focus) + dir
      @focus = FOCUSES[i.clamp(0, FOCUSES.size - 1)]
      @dirty = true
    end

    def move_left
      if @focus == :objects
        row = @objects_rows[@objects_cursor]
        if row[:type] == :group && @expanded.include?(row[:group])
          toggle_group(row[:group])
        elsif row[:type] == :entry && @expanded.include?(row[:group])
          toggle_group(row[:group])
        else
          move_focus(-1)
        end
      else
        move_focus(-1)
      end
    end

    def move_right
      if @focus == :objects
        row = @objects_rows[@objects_cursor]
        if row && row[:type] == :group
          if @expanded.include?(row[:group])
            move_focus(1)
          else
            toggle_group(row[:group])
          end
          return
        end
      end
      move_focus(1)
    end

    def move_cursor(dir)
      case @focus
      when :objects
        @objects_cursor = (@objects_cursor + dir).clamp(0, [@objects_rows.size - 1, 0].max)
        entry = selected_entry
        select_target(entry&.target) if entry&.target != @target
        @dirty = true
      when :methods
        @methods_cursor = (@methods_cursor + dir).clamp(0, [@method_rows.size - 1, 0].max)
        @preview_scroll = 0
        @preview_key = nil
        request_doc
        @dirty = true
      when :preview
        scroll(dir)
      end
    end

    def page_move(dir)
      case @focus
      when :preview then scroll(dir * content_height)
      when :objects then move_cursor(dir * content_height)
      when :methods then move_cursor(dir * content_height)
      end
    end

    def half_page(dir)
      scroll(dir * [content_height / 2, 1].max) if @focus == :preview
    end

    def scroll(dir)
      @preview_scroll += dir
      clamp_scroll
      @dirty = true
    end

    def jump_end(dir)
      case @focus
      when :objects
        @objects_cursor = dir > 0 ? @objects_rows.size - 1 : 0
        entry = selected_entry
        select_target(entry&.target) if entry&.target != @target
        @dirty = true
      when :methods
        @methods_cursor = dir > 0 ? @method_rows.size - 1 : 0
        @preview_scroll = 0
        @preview_key = nil
        request_doc
        @dirty = true
      when :preview
        scroll(dir * @preview_lines.size)
      end
    end

    def activate
      case @focus
      when :objects
        row = @objects_rows[@objects_cursor]
        return if row.nil? || row[:type] == :empty
        if row[:type] == :group
          toggle_group(row[:group])
        else
          @focus = :methods
          @dirty = true
        end
      when :methods
        @focus = :preview
        @dirty = true
      when :preview
        @focus = :methods
        @dirty = true
      end
    end

    def toggle_group(name)
      @expanded.include?(name) ? @expanded.delete(name) : @expanded.add(name)
      refresh_objects
      @objects_cursor = @objects_rows.index { |r| r[:type] == :group && r[:group] == name } || @objects_cursor
      @dirty = true
    end

    def toggle_inherited
      return unless @focus == :methods
      @show_inherited = !@show_inherited
      rebuild_methods(selected_method&.name)
      @preview_key = nil
      request_doc
      @dirty = true
    end

    def jump_anchor(key)
      update_preview
      @preview_scroll = @anchors.fetch(key, 0)
      clamp_scroll
      @dirty = true
    end

    # ---- search ---------------------------------------------------------------

    def start_search
      @search_active = true
      @search_pane = @focus
      @search_buffer = +""
      @dirty = true
    end

    def toggle_search
      if @search_active
        cancel_search
      elsif @focus == :methods && @methods_filter
        clear_methods_filter
      elsif @focus == :objects && @objects_filter
        clear_objects_filter
      else
        start_search
      end
    end

    def clear_objects_filter
      return unless @objects_filter
      keep = selected_entry&.label
      @objects_filter = nil
      refresh_objects
      idx = @objects_rows.index { |r| r[:type] == :entry && r[:entry].label == keep }
      @objects_cursor = idx || @objects_cursor
      entry = selected_entry
      select_target(entry&.target) if entry&.target != @target
      @dirty = true
    end

    def clear_methods_filter
      return unless @methods_filter
      @methods_filter = nil
      rebuild_methods(selected_method&.name)
      @preview_key = nil
      request_doc
      @dirty = true
    end

    def handle_search_key(k)
      case k
      when :esc
        cancel_search
      when :enter
        @search_active = false
        @dirty = true
      when :backspace, :"C-h"
        @search_buffer.chop!
        apply_search
        @dirty = true
      when String
        if k.length == 1 && k.ord >= 0x20
          @search_buffer << k
          apply_search
          @dirty = true
        end
      end
    end

    def apply_search
      q = @search_buffer
      case @search_pane
      when :objects
        @objects_filter = q.empty? ? nil : q
        refresh_objects
        if @objects_filter
          idx = @objects_rows.index { |r| r[:type] == :entry }
          @objects_cursor = idx || 0
        end
        entry = selected_entry
        select_target(entry&.target) if entry&.target != @target
      when :methods
        @methods_filter = q.empty? ? nil : q
        rebuild_methods
        @preview_key = nil
        request_doc
      end
    end

    def cancel_search
      @search_active = false
      if @search_pane == :objects
        @objects_filter = nil
        keep = selected_entry&.label
        refresh_objects
        idx = @objects_rows.index { |r| r[:type] == :entry && r[:entry].label == keep }
        @objects_cursor = idx || @objects_cursor
        entry = selected_entry
        select_target(entry&.target) if entry&.target != @target
      elsif @search_pane == :methods
        @methods_filter = nil
        rebuild_methods(selected_method&.name)
        @preview_key = nil
        request_doc
      end
      @dirty = true
    end

    def clear_filters
      return if @objects_filter.nil? && @methods_filter.nil? && !@search_active
      @search_active = false
      clear_objects_filter
      clear_methods_filter
      @dirty = true
    end

    def search_active = @search_active
    def search_buffer = @search_buffer
    def search_pane = @search_pane

    # ---- main loop ------------------------------------------------------------

    def run
      win_term_setup
      if @stdin.tty?
        @stdin.raw do
          @stdin.echo = false
          inner_run
        end
      else
        inner_run
      end
    ensure
      @stdout.write("\e[0m\e[?25h\e[?1049l\e[2J\e[H")
      win_term_restore
    end

    def win_term_setup
      return unless Gem.win_platform?
      require "fiddle"
      handle_type = Fiddle.const_defined?(:TYPE_INTPTR_T) ? Fiddle::TYPE_INTPTR_T : Fiddle::TYPE_VOIDP
      k32 = Fiddle.dlopen("kernel32.dll")
      get_std = Fiddle::Function.new(k32["GetStdHandle"], [handle_type], Fiddle::TYPE_VOIDP)
      get_mode = Fiddle::Function.new(k32["GetConsoleMode"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG)
      set_mode = Fiddle::Function.new(k32["SetConsoleMode"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG)
      mode = Fiddle::Pointer.malloc(4)
      @win_out = get_std.call(-11)
      out_mode =
        if @win_out && get_mode.call(@win_out, mode) == 1
          mode[0, 4].unpack1("L")
        end
      @win_in = get_std.call(-10)
      in_mode =
        if @win_in && get_mode.call(@win_in, mode) == 1
          mode[0, 4].unpack1("L")
        end
      @saved_mode = out_mode
      if out_mode
        set_mode.call(@win_out, out_mode | 0x0004)
        @saved_cp = Fiddle::Function.new(k32["GetConsoleOutputCP"], [], Fiddle::TYPE_LONG).call
        Fiddle::Function.new(k32["SetConsoleOutputCP"], [Fiddle::TYPE_LONG], Fiddle::TYPE_LONG).call(65001)
      end
      if in_mode
        @saved_in_mode = in_mode
        set_mode.call(@win_in, in_mode | 0x0200)
      end
    rescue StandardError, LoadError
      nil
    end

    def win_term_restore
      return unless Gem.win_platform?
      require "fiddle"
      k32 = Fiddle.dlopen("kernel32.dll")
      set_mode = Fiddle::Function.new(k32["SetConsoleMode"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG)
      set_mode.call(@win_out, @saved_mode) if @win_out && @saved_mode
      set_mode.call(@win_in, @saved_in_mode) if @win_in && @saved_in_mode
      Fiddle::Function.new(k32["SetConsoleOutputCP"], [Fiddle::TYPE_LONG], Fiddle::TYPE_LONG).call(@saved_cp) if @saved_cp
    rescue StandardError, LoadError
      nil
    end

    def inner_run
      @stdout.write("\e[?1049h\e[?25l\e[2J")
      trap("WINCH") { update_geometry; @dirty = true } if Signal.list.key?("WINCH")
      if @once
        wait_docs(2.0)
        render
        return
      end
      if @key_source
        @key_source.each_char do |c|
          break unless @running
          handle_key(Input.parse_char(c))
          render
        end
        wait_docs(1.5)
        render
        return
      end
      main_loop
    end

    def wait_docs(seconds)
      deadline = Time.now + seconds
      while Time.now < deadline
        d = doc
        break if d && d[:ready]
        sleep 0.05
      end
    end

    def main_loop
      input = Input.new(@stdin)
      seen_doc_key = nil
      while @running
        render if @dirty
        k = input.next_key(0.15)
        case k
        when :eof
          @running = false
        when nil
          old = [@height, @width]
          update_geometry
          @dirty = true if old != [@height, @width]
          d = doc
          if d && d[:ready] && seen_doc_key != d[:key]
            seen_doc_key = d[:key]
            @dirty = true
          end
        else
          seen_doc_key = nil
          handle_key(k)
        end
      end
    end

    def render
      old = [@height, @width]
      update_geometry
      clear = (old != [@height, @width]) ? "\e[2J" : ""
      update_preview
      frame = Screen.new(self).frame
      # raw mode disables ONLCR, so emit CRLF explicitly
      frame = frame.gsub("\n", "\r\n")
      @stdout.write("\e[H#{clear}" + frame)
      @stdout.flush
      @dirty = false
    end
  end

  # Reads keys from a raw tty, mapping escape sequences to symbols.
  class Input
    SEQ = {
      "\e[A" => :up, "\e[B" => :down, "\e[C" => :right, "\e[D" => :left,
      "\eOA" => :up, "\eOB" => :down, "\eOC" => :right, "\eOD" => :left,
      "\e[H" => :home, "\e[F" => :end, "\e[1~" => :home, "\e[4~" => :end,
      "\e[5~" => :pgup, "\e[6~" => :pgdn, "\e[3~" => :del,
      "\e[Z" => :stab,
    }.freeze

    def initialize(io)
      @io = io
      @pending = []
      @chunks = []
      @mutex = Mutex.new
      @reader = Thread.new { reader_loop } if Gem.win_platform?
    end

    def next_key(timeout)
      return next_key_threaded(timeout) if @reader
      loop do
        return @pending.shift if @pending.any?
        r = IO.select([@io], nil, nil, timeout)
        return nil unless r
        chunk = @io.read_nonblock(4096, exception: false)
        return :eof if chunk.nil?
        return nil if chunk == :wait_readable || chunk.empty?
        parse_chunk(chunk)
      end
    end

    def reader_loop
      loop do
        chunk =
          if Gem.win_platform? && @io.respond_to?(:getch)
            @io.getch
          else
            @io.readpartial(4096)
          end
        break if chunk.nil?
        @mutex.synchronize { @chunks << chunk }
      end
    rescue StandardError
      nil
    end

    def next_key_threaded(timeout)
      deadline = Time.now + timeout
      loop do
        return @pending.shift if @pending.any?
        if (buf = drain_chunks)
          parse_threaded(buf)
          next
        end
        return :eof if !@reader.alive? && @pending.empty?
        return nil if Time.now >= deadline
        sleep 0.005
      end
    end

    def drain_chunks
      @mutex.synchronize do
        if @chunks.empty?
          nil
        else
          s = @chunks.join
          @chunks.clear
          s
        end
      end
    end

    def parse_threaded(chunk)
      buf = chunk
      until buf.empty?
        if buf.start_with?("\e")
          seq = SEQ.keys.find { |s| buf.start_with?(s) }
          if seq
            @pending << SEQ[seq]
            buf = buf[seq.length..]
          elsif buf.length < 4 && SEQ.keys.any? { |s| s.start_with?(buf) }
            more = drain_chunks
            unless more
              sleep 0.01
              more = drain_chunks
            end
            if more
              buf << more
            else
              @pending << :esc
              buf = buf[1..]
            end
          else
            @pending << :esc
            buf = buf[1..]
          end
        else
          @pending << self.class.parse_char(buf[0])
          buf = buf[1..]
        end
      end
    end

    def parse_chunk(chunk)
      buf = chunk
      until buf.empty?
        if buf.start_with?("\e")
          seq = SEQ.keys.find { |s| buf.start_with?(s) }
          if seq
            @pending << SEQ[seq]
            buf = buf[seq.length..]
          elsif buf.length < 4 && SEQ.keys.any? { |s| s.start_with?(buf) }
            more = nil
            if @io.wait_readable(0.02)
              more = @io.read_nonblock(64, exception: false)
            end
            if more.is_a?(String) && !more.empty?
              buf << more
            else
              @pending << :esc
              buf = buf[1..]
            end
          else
            @pending << :esc
            buf = buf[1..]
          end
        else
          @pending << self.class.parse_char(buf[0])
          buf = buf[1..]
        end
      end
    end

    def self.parse_char(ch)
      case ch
      when "\r", "\n" then :enter
      when "\t" then :tab
      when "\e" then :esc
      when "\x7f", "\b" then :backspace
      when "\x03" then :"C-c"
      when "\x04" then :"C-d"
      when "\x15" then :"C-u"
      when "\x01" then :"C-a"
      when "\x05" then :"C-e"
      else
        ch
      end
    end
  end
end
