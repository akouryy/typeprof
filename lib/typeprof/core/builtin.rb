module TypeProf::Core
  class Builtin
    def initialize(genv)
      @genv = genv
    end

    def class_new(node, ty, a_args, ret)
      edges = []
      ty = ty.get_instance_type
      recv = Source.new(ty)
      site = CallSite.new(node, @genv, recv, :initialize, a_args, nil) # TODO: block
      # TODO: dup check
      i = 0
      i += 1 while node.sites.include?([:class_new, i])
      node.add_site([:class_new, i], site)
      # site.ret (the return value of initialize) is discarded
      edges << [Source.new(ty), ret]
    end

    def proc_call(node, ty, a_args, ret)
      edges = []
      case ty
      when Type::Proc
        if a_args.size == ty.block.f_args.size
          a_args.zip(ty.block.f_args) do |a_arg, f_arg|
            edges << [a_arg, f_arg]
          end
        end
        edges << [ty.block.ret, ret]
      else
        puts "??? proc_call"
      end
      edges
    end

    def module_include(node, ty, a_args, ret)
      case ty
      when Type::Module
        cpath = ty.cpath
        a_args.each do |a_arg|
          a_arg.types.each do |ty, _source|
            case ty
            when Type::Module
              # TODO: undo
              @genv.add_module_include(cpath, ty.cpath)
            else
              puts "??? module_include"
            end
          end
        end
      else
        puts "??? module_include"
      end
      []
    end

    def array_aref(node, ty, a_args, ret)
      edges = []
      if a_args.size == 1
        case ty
        when Type::Array
          idx = node.positional_args[0]
          if idx.is_a?(AST::LIT) && idx.lit.is_a?(Integer)
            idx = idx.lit
          else
            idx = nil
          end
          edges << [ty.get_elem(idx), ret]
        else
          puts "??? array_aref"
        end
      else
        puts "??? array_aref"
      end
      edges
    end

    def array_aset(node, ty, a_args, ret)
      edges = []
      if a_args.size == 2
        case ty
        when Type::Array
          val = a_args[1]
          idx = node.positional_args[0]
          if idx.is_a?(AST::LIT) && idx.lit.is_a?(Integer) && ty.get_elem(idx.lit)
            edges << [val, ty.get_elem(idx.lit)]
          else
            edges << [val, ty.get_elem]
          end
        else
          puts "??? array_aset"
        end
      else
        puts "??? array_aset"
      end
      edges
    end

    def hash_aref(node, ty, a_args, ret)
      edges = []
      if a_args.size == 1
        case ty
        when Type::Hash
          idx = node.positional_args[0]
          if idx.is_a?(AST::LIT) && idx.lit.is_a?(Symbol)
            idx = idx.lit
          else
            idx = nil
          end
          edges << [ty.get_value(idx), ret]
        else
          puts "??? hash_aref 1"
        end
      else
        puts "??? hash_aref 2"
      end
      edges
    end

    def hash_aset(node, ty, a_args, ret)
      edges = []
      if a_args.size == 2
        case ty
        when Type::Hash
          val = a_args[1]
          idx = node.positional_args[0]
          if idx.is_a?(AST::LIT) && idx.lit.is_a?(Symbol) && ty.get_value(idx.lit)
            # TODO: how to handle new key?
            edges << [val, ty.get_value(idx.lit)]
          else
            # TODO: literal_pairs will not be updated
            edges << [val, ty.get_value]
          end
        else
          puts "??? hash_aset 1 #{ ty.object_id } #{ ty.inspect }"
        end
      else
        puts "??? hash_aset 2"
      end
      edges
    end

    def deploy
      {
        class_new: [[:Class], false, :new],
        proc_call: [[:Proc], false, :call],
        module_include: [[:Module], false, :include],
        array_aref: [[:Array], false, :[]],
        array_aset: [[:Array], false, :[]=],
        hash_aref: [[:Hash], false, :[]],
        hash_aset: [[:Hash], false, :[]=],
      }.each do |key, (cpath, singleton, mid)|
        me = @genv.resolve_meth(cpath, singleton, mid)
        me.builtin = method(key)
      end
    end
  end
end