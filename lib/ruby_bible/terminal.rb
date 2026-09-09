module RubyBible
  # Windows console mode handling: enables VT output, UTF-8 and VT input
  # (so arrow keys and mouse arrive as ANSI/SGR sequences through normal
  # reads on Windows). Every method is a no-op elsewhere.
  module Terminal
    module_function

    def windows? = Gem.win_platform?

    def setup
      return unless windows?
      load_k32
      @out = std(-11)
      @in  = std(-10)
      @saved_out = mode(@out)
      @saved_in  = mode(@in)
      set_mode(@out, @saved_out | 0x0004) if @saved_out # VT output
      set_mode(@in,  @saved_in  | 0x0200) if @saved_in  # VT input
      @saved_out_cp = codepage
      @saved_in_cp  = in_codepage
      set_cp(65001)     # UTF-8 output
      set_in_cp(65001)  # UTF-8 input
      utf8_io
    end

    def restore
      return if !windows? || !@k32
      set_mode(@out, @saved_out) if @saved_out
      set_mode(@in,  @saved_in)  if @saved_in
      set_cp(@saved_out_cp) if @saved_out_cp
      set_in_cp(@saved_in_cp) if @saved_in_cp
    end

    def enable_vt_input
      return unless windows? && @in
      set_mode(@in, mode(@in) | 0x0200)
    end

    # Make Ruby write UTF-8 bytes directly, so the box-drawing and symbol
    # glyphs are never transcoded into the legacy console codepage.
    def utf8_io
      [$stdout, $stderr].each { |io| io.set_encoding(Encoding::UTF_8) }
      $stdout.sync = true
    rescue StandardError
      nil
    end

    # ---- Win32 plumbing ----

    def load_k32
      require "fiddle"
      @ptr = Fiddle.const_defined?(:TYPE_INTPTR_T) ? Fiddle::TYPE_INTPTR_T : Fiddle::TYPE_VOIDP
      @k32 = Fiddle.dlopen("kernel32.dll")
    rescue LoadError, StandardError
      nil
    end

    def std(id)
      f("GetStdHandle", [@ptr], Fiddle::TYPE_VOIDP)&.call(id)
    end

    def mode(h)
      return unless h
      buf = Fiddle::Pointer.malloc(4)
      return unless f("GetConsoleMode", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG)&.call(h, buf) == 1
      buf[0, 4].unpack1("L")
    end

    def set_mode(h, m)
      return unless h && m
      f("SetConsoleMode", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG], Fiddle::TYPE_LONG)&.call(h, m)
    end

    def codepage
      f("GetConsoleOutputCP", [], Fiddle::TYPE_LONG)&.call
    end

    def in_codepage
      f("GetConsoleCP", [], Fiddle::TYPE_LONG)&.call
    end

    def set_cp(cp)
      f("SetConsoleOutputCP", [Fiddle::TYPE_LONG], Fiddle::TYPE_LONG)&.call(cp)
    end

    def set_in_cp(cp)
      f("SetConsoleCP", [Fiddle::TYPE_LONG], Fiddle::TYPE_LONG)&.call(cp)
    end

    def f(name, args, ret)
      Fiddle::Function.new(@k32[name], args, ret)
    rescue StandardError
      nil
    end
  end
end
