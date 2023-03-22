module TypeProf::Core
  class AST
    def self.parse(text_id, src)
      raw_scope = RubyVM::AbstractSyntaxTree.parse(src, keep_tokens: true)

      raise unless raw_scope.type == :SCOPE
      _tbl, args, raw_body = raw_scope.children
      raise unless args == nil

      cref = CRef.new([], false, nil)
      lenv = LexicalScope.new(text_id, nil, cref, nil)
      Fiber[:tokens] = raw_scope.all_tokens.map do |_idx, type, str, (row1, col1, row2, col2)|
        if type == :tIDENTIFIER
          pos1 = TypeProf::CodePosition.new(row1, col1)
          pos2 = TypeProf::CodePosition.new(row2, col2)
          code_range = TypeProf::CodeRange.new(pos1, pos2)
          [type, str, code_range]
        end
      end.compact.sort_by {|_type, _str, code_range| code_range.first }
      AST.create_node(raw_body, lenv)
    end

    def self.create_node(raw_node, lenv)
      case raw_node.type

      # definition
      when :BLOCK then BLOCK.new(raw_node, lenv)
      when :MODULE then MODULE.new(raw_node, lenv)
      when :CLASS then CLASS.new(raw_node, lenv)
      when :DEFN then DEFN.new(raw_node, lenv)
      when :DEFS then DEFS.new(raw_node, lenv)
      when :BEGIN then BEGIN_.new(raw_node, lenv)

      # control
      when :IF then IF.new(raw_node, lenv)
      when :UNLESS then UNLESS.new(raw_node, lenv)
      when :AND then AND.new(raw_node, lenv)
      when :RETURN then RETURN.new(raw_node, lenv)
      when :RESCUE then RESCUE.new(raw_node, lenv)

      # variable
      when :CONST then CONST.new(raw_node, lenv)
      when :COLON2 then COLON2.new(raw_node, lenv)
      when :CDECL then CDECL.new(raw_node, lenv)
      when :IVAR then IVAR.new(raw_node, lenv)
      when :IASGN then IASGN.new(raw_node, lenv)
      when :LVAR, :DVAR then LVAR.new(raw_node, lenv)
      when :LASGN, :DASGN then LASGN.new(raw_node, lenv)

      # value
      when :SELF then SELF.new(raw_node, lenv)
      when :LIT then LIT.new(raw_node, lenv, raw_node.children.first)
      when :STR then LIT.new(raw_node, lenv, raw_node.children.first) # Using LIT is OK?
      when :TRUE then LIT.new(raw_node, lenv, true) # Using LIT is OK?
      when :FALSE then LIT.new(raw_node, lenv, false) # Using LIT is OK?
      when :ZLIST, :LIST then LIST.new(raw_node, lenv)

      # call
      when :ITER
        raw_call, raw_block = raw_node.children
        AST.create_call_node(raw_node, raw_call, raw_block, lenv)
      else
        create_call_node(raw_node, raw_node, nil, lenv)
      end
    end

    def self.create_call_node(raw_node, raw_call, raw_block, lenv)
      case raw_call.type
      when :CALL then CALL.new(raw_node, raw_call, raw_block, lenv)
      when :VCALL then VCALL.new(raw_node, raw_call, raw_block, lenv)
      when :FCALL then FCALL.new(raw_node, raw_call, raw_block, lenv)
      when :OPCALL then OPCALL.new(raw_node, raw_call, raw_block, lenv)
      when :ATTRASGN then ATTRASGN.new(raw_node, raw_call, raw_block, lenv)
      else
        pp raw_node
        raise "not supported yet: #{ raw_node.type }"
      end
    end

    def self.parse_cpath(raw_node, base_cpath)
      names = []
      while raw_node
        case raw_node.type
        when :CONST
          name, = raw_node.children
          names << name
          break
        when :COLON2
          raw_node, name = raw_node.children
          names << name
        when :COLON3
          name, = raw_node.children
          names << name
          return names.reverse
        else
          return nil
        end
      end
      return base_cpath + names.reverse
    end

    def self.find_sym_code_range(start_pos, sym)
      tokens = Fiber[:tokens]
      i = tokens.bsearch_index {|_type, _str, code_range| start_pos <= code_range.first }
      if i
        while tokens[i]
          type, str, code_range = tokens[i]
          return code_range if type == :tIDENTIFIER && str == sym.to_s
          i += 1
        end
      end
      return nil
    end

    class Node
      def initialize(raw_node, lenv)
        @raw_node = raw_node
        @lenv = lenv
        @raw_children = raw_node.children
        @prev_node = nil
        @ret = nil
        @text_id = lenv.text_id
        @defs = nil
        @sites = nil
      end

      attr_reader :lenv, :prev_node, :ret

      def subnodes
        {}
      end

      def attrs
        {}
      end

      def traverse(&blk)
        yield :enter, self
        subnodes.each_value do |subnode|
          subnode.traverse(&blk) if subnode
        end
        yield :leave, self
      end

      def code_range
        if @raw_node
          @code_range ||= TypeProf::CodeRange.from_node(@raw_node)
        else
          pp self
          nil
        end
      end

      def defs
        @defs ||= Set[]
      end

      def add_def(genv, d)
        defs << d
        case d
        when MethodDef
          genv.add_method_def(d)
        when ConstDef
          genv.add_const_def(d)
        when IVarDef
          genv.add_ivar_def(d)
        end
      end

      def sites
        @sites ||= {}
      end

      def add_site(key, site)
        sites[key] = site
      end

      def install(genv)
        debug = ENV["TYPEPROF_DEBUG"]
        if debug
          puts "install enter: #{ self.class }@#{ code_range.inspect }"
        end
        @ret = install0(genv)
        if debug
          puts "install leave: #{ self.class }@#{ code_range.inspect }"
        end
        @ret
      end

      def uninstall(genv)
        debug = ENV["TYPEPROF_DEBUG"]
        if debug
          puts "uninstall enter: #{ self.class }@#{ code_range.inspect }"
        end
        unless @reused
          if @defs
            @defs.each do |d|
              case d
              when MethodDef
                genv.remove_method_def(d)
              when ConstDef
                genv.remove_const_def(d)
              when IVarDef
                genv.remove_ivar_def(d)
              end
            end
          end
          if @sites
            @sites.each_value do |site|
              site.destroy(genv)
            end
          end
        end
        uninstall0(genv)
        if debug
          puts "uninstall leave: #{ self.class }@#{ code_range.inspect }"
        end
      end

      def uninstall0(genv)
        subnodes.each_value do |subnode|
          subnode.uninstall(genv) if subnode
        end
      end

      def diff(prev_node)
        if prev_node.is_a?(self.class) && attrs.all? {|key, attr| attr == prev_node.send(key) }
          subnodes.each do |key, subnode|
            prev_subnode = prev_node.send(key)
            if subnode && prev_subnode
              subnode.diff(prev_subnode)
              return unless subnode.prev_node
            else
              return if subnode != prev_subnode
            end
          end
          @prev_node = prev_node
        end
      end

      def reuse
        @lenv = @prev_node.lenv
        @ret = @prev_node.ret
        @defs = @prev_node.defs
        @sites = @prev_node.sites

        subnodes.each_value do |subnode|
          subnode.reuse if subnode
        end
      end

      def hover(pos, &blk)
        if code_range.include?(pos)
          subnodes.each_value do |subnode|
            next unless subnode
            subnode.hover(pos, &blk)
          end
          yield self
        end
        return nil
      end

      def dump(dumper)
        s = dump0(dumper)
        if @sites && !@sites.empty?
          s += "\e[32m:#{ @sites.to_a.join(",") }\e[m"
        end
        s += "\e[34m:#{ @ret.inspect }\e[m"
        s
      end

      def diagnostics(genv, &blk)
        if @sites
          @sites.each_value do |site|
            next unless site.respond_to?(:diagnostics) # XXX
            site.diagnostics(genv, &blk)
          end
        end
        subnodes.each_value do |subnode|
          subnode.diagnostics(genv, &blk) if subnode
        end
      end

      def get_vertexes_and_boxes(vtxs, boxes)
        if @sites
          @sites.each_value do |site|
            vtxs << site.ret
            boxes << site
          end
        end
        vtxs << @ret
        subnodes.each_value do |subnode|
          subnode.get_vertexes_and_boxes(vtxs, boxes) if subnode
        end
      end

      def pretty_print_instance_variables
        super - [:@raw_node, :@raw_children, :@lenv, :@prev_node]
      end
    end

    class DummySymbolNode
      def initialize(sym, code_range, ret)
        @sym = sym
        @code_range = code_range
        @ret = ret
      end

      attr_reader :lenv, :prev_node, :ret

      def sites
        {}
      end
    end
  end

  class LexicalScope
    def initialize(text_id, node, cref, outer)
      @text_id = text_id
      @node = node
      @cref = cref
      @tbl = {} # variable table
      @outer = outer
      # XXX
      @self = Source.new(@cref.get_self)
      @ret = node ? Vertex.new("ret", node) : nil
    end

    attr_reader :text_id, :cref, :outer

    def resolve_var(name)
      lenv = self
      while lenv
        break if lenv.var_exist?(name)
        lenv = lenv.outer
      end
      lenv
    end

    def def_var(name, node)
      @tbl[name] ||= Vertex.new("var:#{ name }", node)
    end

    def get_var(name)
      @tbl[name]
    end

    def var_exist?(name)
      @tbl.key?(name)
    end

    def get_self
      @self
    end

    def get_ret
      @ret
    end
  end

  class CRef
    def initialize(cpath, singleton, outer)
      @cpath = cpath
      @singleton = singleton
      @outer = outer
    end

    attr_reader :cpath, :singleton, :outer

    def extend(cpath, singleton)
      CRef.new(cpath, singleton, self)
    end

    def get_self
      (@singleton ? Type::Module : Type::Instance).new(@cpath || [:Object])
    end
  end
end