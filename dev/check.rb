$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ruby_bible"
I = RubyBible::Introspect

ref = ->(t, n, s = false) { RubyBible::Introspect::MethodRef.new(target: t, name: n, singleton: s, owner_target: t) }

# 1. source extraction for Ruby-defined method
src = I.source(ref.(Set, :add))
puts "Set#add (#{src.lines.size} lines):"
puts src

# endless def
module EndlessTest
  def self.twice(x) = x * 2
end
src2 = I.source(ref.(EndlessTest, :twice, true))
puts "endless def ok: #{src2&.strip == 'def self.twice(x) = x * 2'}"

# 2. C method
puts "String#gsub location: #{I.location(ref.(String, :gsub))}"

# 3. signature + visibility
puts "sig: #{I.signature(ref.(Set, :add))} · vis: #{I.visibility(ref.(Set, :add))}"

# 4. docs pipeline (gem docs installed)
text, = RubyBible::Docs.for_method(ref.(BigDecimal, :*))
puts "BigDecimal#* docs: #{text ? "#{text.lines.size} lines" : "nil"}"

# 5. app preview build for a method
app = RubyBible::App.new(once: true)
app.instance_variable_set(:@target, Set)
app.send(:rebuild_methods)
rows = app.instance_variable_get(:@method_rows)
app.instance_variable_set(:@methods_cursor, rows.index { |r| r[:type] == :method && r[:ref].name == :add } || 0)
app.instance_variable_set(:@doc_state, { key: app.doc_key, ready: true, text: nil, topic: nil })
lines = app.preview_lines
puts "preview lines: #{lines.size}, anchors: #{app.instance_variable_get(:@anchors)}"
puts lines.first(10).map { |l| RubyBible::Ansi.strip(l) }

# 6. inherited groups
inst, sing = I.inherited_method_groups(Set)
puts "Set inherited: #{inst.size} instance groups, #{sing.size} singleton groups"
puts inst.map { |o, _| o.name }.first(6).inspect
