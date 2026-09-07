module RubyBible
  # Live introspection: method lists, signatures, arity, visibility and
  # extracted source for Ruby-defined methods.  All of this comes from the
  # running interpreter.
  module Introspect
    MethodRef = Struct.new(:target, :name, :singleton, :owner_target, :doc_owner,
                           keyword_init: true) do
      def label = name.to_s
      def instance? = !singleton
    end

    module_function

    # -> { instance: [MethodRef,...], singleton: [MethodRef,...] }
    def own_methods(target)
      doc_owner = target.is_a?(Module) ? nil : target.to_s
      if target.is_a?(Module)
        {
          instance: target.instance_methods(false).sort.map { |n| MethodRef.new(target:, name: n, singleton: false, owner_target: target) },
          singleton: target.singleton_methods(false).sort.map { |n| MethodRef.new(target:, name: n, singleton: true, owner_target: target) },
        }
      else # plain object like ARGF/ENV
        cls = target.class
        inst = cls.equal?(Object) ? [] : cls.instance_methods(false)
        {
          instance: inst.sort.map { |n| MethodRef.new(target:, name: n, singleton: false, owner_target: target, doc_owner:) },
          singleton: target.singleton_methods(false).sort.map { |n| MethodRef.new(target:, name: n, singleton: true, owner_target: target, doc_owner:) },
        }
      end
    end

    # All methods including inherited ones, grouped by defining ancestor.
    def inherited_method_groups(target)
      inst, sing = [], []
      if target.is_a?(Module)
        target.ancestors.each do |anc|
          next if anc.is_a?(Class) && anc.name.to_s.empty?
          ms = anc.instance_methods(false).sort
          inst << [anc, ms.map { |n| MethodRef.new(target:, name: n, singleton: false, owner_target: anc) }] unless ms.empty?
        end
        singleton_ancestors(target).each do |anc|
          ms = anc.instance_methods(false).sort
          next if ms.empty?
          label = anc.name ? ".#{anc.name}" : ". #{anc}"
          sing << [label, ms.map { |n| MethodRef.new(target:, name: n, singleton: true, owner_target: anc) }]
        end
      else
        inst << [target, target.singleton_methods(false).sort.map { |n| MethodRef.new(target:, name: n, singleton: false, owner_target: target) }]
        inst.reject! { |_, ms| ms.empty? }
        sing = []
      end
      [inst, sing]
    end

    def singleton_ancestors(target)
      target.singleton_class.ancestors.select do |a|
        a.is_a?(Class) && (a.name || a.to_s =~ /Class:/)
      end
    rescue StandardError
      [target.singleton_class]
    end

    def method_object(ref)
      if ref.target.is_a?(Module)
        ref.singleton ? ref.target.method(ref.name) : ref.target.instance_method(ref.name)
      elsif ref.singleton
        ref.target.method(ref.name)
      else
        # plain object instance method: bind via singleton owner
        ref.target.method(ref.name)
      end
    end

    def signature(ref)
      m = method_object(ref)
      params = format_parameters(m.parameters)
      owner = pretty_owner(ref)
      sep = ref.singleton ? "." : "#"
      receiver = ref.target.is_a?(Module) ? ref.target.name : pretty_owner(ref)
      "#{receiver}#{sep}#{ref.name}(#{params.join(', ')})"
    rescue StandardError
      ref.name.to_s
    end

    def pretty_owner(ref)
      if ref.target.is_a?(Module)
        ref.target.name
      else
        ref.target.class.equal?(Object) ? "self" : ref.target.class.name
      end
    end

    def format_parameters(pairs)
      seq = -1
      pairs.filter_map do |(kind, name)|
        n = name ? name.to_s : ""
        case kind
        when :req
          seq += 1
          n.empty? ? "arg#{seq}" : n
        when :opt
          seq += 1
          "#{n.empty? ? "arg#{seq}" : n} = ?"
        when :rest then "*#{n.empty? ? 'args' : n}"
        when :keyreq then "#{n}:"
        when :key then "#{n}: ?"
        when :keyrest then "**#{n.empty? ? 'opts' : n}"
        when :block then "&#{n.empty? ? 'blk' : n}"
        end
      end
    end

    def visibility(ref)
      t = ref.target
      if t.is_a?(Module) && !ref.singleton
        if t.private_method_defined?(ref.name, false) then :private
        elsif t.protected_method_defined?(ref.name, false) then :protected
        else :public
        end
      else
        :public
      end
    rescue StandardError
      :public
    end

    def arity_str(ref)
      m = method_object(ref)
      a = m.arity
      base = a >= 0 ? a.to_s : "#{-a - 1}+"
      "arity #{base}"
    rescue StandardError
      ""
    end

    # -> "C builtin" | "path:line"
    def location(ref)
      loc = method_object(ref)&.source_location
      return "C builtin (no Ruby source)" if loc.nil?
      "#{loc[0]}:#{loc[1]}"
    end

    def ruby_defined?(ref)
      !method_object(ref)&.source_location.nil?
    end

    # Extract source code for a Ruby-defined method. Uses the built-in
    # AbstractSyntaxTree to find exact line ranges; falls back to a
    # keyword-depth scan.
    def source(ref)
      m = method_object(ref)
      return nil unless (loc = m.source_location)
      file, line = loc
      return nil unless File.readable?(file)
      all_lines = File.foreach(file).to_a
      max = all_lines.size
      node = ast_range(m)
      range =
        if node&.last_lineno
          [node.first_lineno, node.last_lineno]
        else
          scan_range(all_lines, line, max)
        end
      return nil unless range
      from, to = range
      to = max if to > max
      body = all_lines[(from - 1)...to].join
      if body.lines.size < 400
        body
      else
        body.lines.first(400).join + "...\n"
      end
    rescue StandardError
      nil
    end

    def ast_range(m)
      RubyVM::AbstractSyntaxTree.of(m)
    rescue StandardError
      nil
    end

    # Fallback: scan from `line` until keyword depth returns to zero.
    def scan_range(lines, line, max)
      from = [line, 1].max
      first = lines[from - 1].to_s
      # endless method: `def name = expr` / `def name(x) = expr`
      return [from, from] if first.match?(/\A\s*def\s+(?:self\.)?[a-zA-Z_]\w*[?!=]?\s*=/) ||
                             first.match?(/\A\s*def\s+(?:self\.)?[a-zA-Z_]\w*[?!=]?\s*\([^)]*\)\s*=/)
      depth = 0
      i = from
      while i <= max && i - from < 600
        l = lines[i - 1].to_s
        depth += count_openers(l)
        depth -= l.scan(/\bend\b/).size
        return [from, i] if depth <= 0
        i += 1
      end
      [from, [from + 60, max].min]
    end

    OPENERS = /\b(def|class|module|case|begin)\b/.freeze
    LEADING_MODIFIERS = /\A\s*(if|unless|while|until|for)\b/.freeze
    MODIFIERS = /(?:\A|[\s(=,\[&|?:]\s*)(if|unless|while|until|for)\b/.freeze
    DOWORD = /\bdo\b/.freeze

    def count_openers(line)
      code = line.gsub(/"(?:[^"\\]|\\.)*"/, "\"\"")
                 .gsub(/'(?:[^'\\]|\\.)*'/, "''")
                 .gsub(/#.*$/, "")
      n = code.scan(OPENERS).size
      n += code.scan(MODIFIERS).size
      # `do` opens a block unless the line already counted a while/until/for
      n += code.scan(DOWORD).size unless code.match?(LEADING_MODIFIERS)
      n
    end
  end
end
