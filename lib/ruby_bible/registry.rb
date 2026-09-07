require "set"
require "pathname"
require "ostruct"
require "securerandom"
require "tempfile"
require "socket"
require "csv"
require "json"
require "net/http"
require "bigdecimal"

module RubyBible
  # Catalog of browsable targets, grouped by topic.
  # Everything is resolved from the running interpreter -- no hand-written
  # descriptions; the app asks Ruby itself what exists and ri for the text.
  module Registry
    Entry = Struct.new(:label, :target, :kind, keyword_init: true) # kind: :class | :module | :object

    GROUPS = {
      "Core" => %w[
        Object BasicObject Module Class Kernel Comparable Enumerable Proc
        Method UnboundMethod Binding Fiber Symbol Refinement Random
      ],
      "Collections" => %w[
        Array Hash Set Range Struct Enumerator Enumerator::Lazy
        Enumerator::Chain OpenStruct
      ],
      "Strings & patterns" => %w[
        String Regexp MatchData Encoding Encoding::Converter
      ],
      "Numbers & math" => %w[
        Numeric Integer Float Rational Complex Math BigDecimal
      ],
      "Time & process" => %w[
        Time Process Process::Status Process::Sys GC GC::Profiler
        ObjectSpace Signal
      ],
      "IO & files" => %w[
        IO File Dir FileTest File::Stat Pathname Tempfile StringIO
      ],
      "Networking" => %w[
        Socket BasicSocket IPSocket TCPSocket TCPServer UDPSocket
        UNIXSocket UNIXServer Addrinfo Net::HTTP Net::HTTP::Get Net::HTTP::Post
      ],
      "Data & encoding" => %w[
        JSON CSV Marshal Data
      ],
      "Concurrency" => %w[
        Thread Thread::Mutex Thread::Backtrace Thread::Backtrace::Location
        ThreadGroup Queue SizedQueue ConditionVariable Monitor Ractor
      ],
      "Errors" => %w[
        Exception StandardError ArgumentError NameError NoMethodError
        KeyError IndexError TypeError ZeroDivisionError RangeError
        RuntimeError StopIteration NotImplementedError SystemExit
        SignalException IOError EOFError RegexpError LocalJumpError
        FrozenError SecurityError ThreadError UncaughtThrowError
      ],
    }.freeze

    SINGLETON_OBJECTS = %w[ARGF ENV].freeze

    SKIP_EVERYTHING = %w[
      RubyBible Gem Bundler Rake Minitest IRB DidYouMean TypeProf Prism PP
    ].freeze

    module_function

    def resolve(name)
      base, _, nested = name.partition("::")
      return unless Object.const_defined?(base)
      target =
        if nested && !nested.empty?
          parent = Object.const_get(base)
          leaf = nested.split("::").last
          return unless parent.const_defined?(leaf)
          parent.const_get(leaf)
        else
          Object.const_get(base)
        end
      return unless target.is_a?(Module) && target.name
      kind = target.is_a?(Class) ? :class : :module
      Entry.new(label: target.name, target: target, kind: kind)
    rescue StandardError
      nil
    end

    def resolve_object(name)
      return unless Object.const_defined?(name)
      target = Object.const_get(name)
      return if target.is_a?(Module)
      Entry.new(label: name, target: target, kind: :object)
    rescue StandardError
      nil
    end

    # Returns [["Group", [Entry,...]], ...]
    def groups
      @groups ||=
        begin
          out = GROUPS.map do |name, consts|
            entries = consts.filter_map { |c| resolve(c) }
            [name, entries]
          end
          objs = SINGLETON_OBJECTS.filter_map { |o| resolve_object(o) }
          out << ["Singleton objects", objs] unless objs.empty?
          out
        end
    end

    # All top-level classes/modules reachable from Object.constants.
    def everything
      @everything ||=
        Object.constants.filter_map do |c|
          next if SKIP_EVERYTHING.include?(c.to_s)
          resolve(c.to_s)
        end.sort_by { |e| [e.kind == :class ? 0 : 1, e.label.downcase] }
    end

    def kind_tag(kind)
      case kind
      when :class then "[C]"
      when :module then "[M]"
      when :object then "[O]"
      else "[?]"
      end
    end
  end
end
