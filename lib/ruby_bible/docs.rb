require "open3"
require "stringio"
require "thread"

module RubyBible
  # Documentation pulled from RDoc's ri database. No content is written by
  # hand -- descriptions, usage notes and examples all come straight from
  # the installed Ruby/gem documentation.
  #
  # Lookups run in-process via RDoc::RI::Driver (~0-5ms after a one-time
  # ~100ms init) with a fallback to spawning `ri` when RDoc is unusable.
  module Docs
    LOCK = Mutex.new
    FORMATS = %w[markdown bs to_s].freeze
    LOCAL_ROOT = File.expand_path("~/.local/share/ruby-bible/ri").freeze

    module_function

    # A local (no-sudo) copy of the core ri database, e.g. produced by
    # dev/fetch-core-docs.sh. Layout: <root>/<abi-version>/system/
    def local_core_dirs
      @local_core_dirs ||=
        Dir.glob(File.join(LOCAL_ROOT, "*", "system")).select { |d| File.directory?(d) }.sort.reverse
    end

    def ri_binary?
      @ri ||= system("ri", "--help", out: File::NULL, err: File::NULL) ? true : false
    end

    # Lazily initialised in-process RI driver. Must be called under LOCK.
    def ensure_driver
      return @driver if @driver_state == :ok
      return nil if @driver_state == :failed
      require "rdoc/ri/driver"
      opts = {
        formatter: RDoc::Markup::ToMarkdown,
        use_stdout: true,
        no_page: true,
      }
      dirs = local_core_dirs
      opts[:extra_doc_dirs] = dirs unless dirs.empty?
      @driver = RDoc::RI::Driver.new(opts)
      @driver_state = :ok
      @driver
    rescue StandardError, LoadError => e
      @driver_error = e
      @driver_state = :failed
      nil
    end

    def driver_state
      @driver_state ||= :none
    end

    # topic like "String", "String#gsub", "ENV.[]"; kind :method | :class
    def fetch(topic, kind)
      LOCK.synchronize do
        cache[topic] ||=
          if (d = ensure_driver)
            in_process(d, topic, kind)
          else
            subprocess(topic)
          end
      end
    end

    def in_process(driver, topic, kind)
      io = StringIO.new
      old = $stdout
      $stdout = io
      begin
        case kind
        when :method then driver.display_method(topic)
        when :class  then driver.display_class(topic)
        else driver.display_name(topic)
        end
        text = io.string
        text.strip.empty? ? nil : clean(text)
      rescue RDoc::RI::Driver::NotFoundError
        nil
      ensure
        $stdout = old
      end
    end

    def subprocess_dirs
      local_core_dirs.flat_map { |d| ["--doc-dir", d] }
    end

    def subprocess(topic)
      return nil unless ri_binary?
      out, _err, st = Open3.capture3("ri", "-T", "-f", format, *subprocess_dirs, topic)
      return nil unless st.success? && !out.strip.empty?
      clean(out)
    end

    # Prefer the markdown formatter; fall back to whatever ri supports.
    def format
      @format ||=
        begin
          f = "bs"
          FORMATS.each do |cand|
            out, _err, st = Open3.capture3("ri", "-T", "-f", cand, "BigDecimal")
            if st.success? && !out.strip.empty?
              f = cand
              break
            end
          end
          f
        end
    end

    def clean(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      text.scrub!
      # markdown output is clean; strip stray ANSI/backspaces just in case
      text = text.gsub(/.\x08/, "").gsub(/[\e]\[[0-9;]*[A-Za-z]/, "").gsub("\x08", "")
      text.sub(/\n?-----+\n?/, "").rstrip
    end

    def cache
      @cache ||= {}
    end

    # Initialise the driver and detect whether core (C-level) docs exist.
    def warmup
      LOCK.synchronize do
        ensure_driver
        @core_docs = !in_process_with_init("String#each_char", :method).nil?
      end
      @warmed = true
    rescue StandardError
      @warmed = true
    end

    def in_process_with_init(topic, kind)
      d = ensure_driver
      return nil unless d
      in_process(d, topic, kind)
    end

    def warmed?
      @warmed == true
    end

    def core_docs?
      @core_docs == true
    end

    def install_hint
      return nil if core_docs?
      return "ri/rdoc unavailable -- `gem install rdoc`" if !ri_binary? && driver_state != :ok
      "core docs missing -- `sudo pacman -S ruby-docs` or run dev/fetch-core-docs.sh"
    end

    # ref is an Introspect::MethodRef; tries ri topic spellings scoped to
    # the owner. No global bare-name fallback: it can return docs for a
    # same-named method of an unrelated class.
    def for_method(ref)
      owner_name =
        ref.doc_owner ||
        (ref.target.is_a?(Module) ? ref.target.name : ref.target.class.name)
      sep = ref.singleton ? "." : "#"
      candidates = ["#{owner_name}#{sep}#{ref.name}"]
      candidates << "#{owner_name}##{ref.name}" if ref.singleton
      candidates.each do |t|
        if (text = fetch(t, :method))
          return [text, t]
        end
      end
      [nil, candidates.first]
    end

    def for_class(target)
      name = target.is_a?(Module) ? target.name : target.to_s
      name ? [fetch(name, :class), name] : nil
    end
  end
end
