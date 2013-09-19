#!ruby
# Generates mruby bindings from pkg definition.

STATIC = 1 << 0
ATTR_ACCESSOR = 1 << 1
CONSTRUCTOR = 1 << 2

def is_static?(flag)
  return flag & STATIC != 0
end

def is_attr_accessor?(flag)
  return flag & ATTR_ACCESSOR != 0
end

def is_constructor?(flag)
  return flag & CONSTRUCTOR != 0
end

def get_plain_type(type)
  type.gsub(/(&|\*|const)/, '').strip
end

def is_pointer_type(type)
  type.index('*')
end


class MrubyStubGenerator
  def put_header
    print <<EOD
#{Header}
#include "mruby.h"
#include "mruby/class.h"
#include "mruby/data.h"
#include "mruby/string.h"
#include "mruby/variable.h"
#include <new>

static void dummy(mrb_state *mrb, void *ptr) {
  //printf("dummy called\\n");
}

// TODO: Use different data type for each class.
static struct mrb_data_type dummy_type = { "Dummy", dummy };

static float get_bool(mrb_value x) {
  return mrb_bool(x);
}

static float get_int(mrb_value x) {
  if (mrb_fixnum_p(x)) {
    return mrb_fixnum(x);
  } else if (mrb_float_p(x)) {
    return mrb_float(x);
  } else {
    return 0;
  }
}

static float get_float(mrb_value x) {
  if (mrb_fixnum_p(x)) {
    return mrb_fixnum(x);
  } else if (mrb_float_p(x)) {
    return mrb_float(x);
  } else {
    return 0;
  }
}

static mrb_value getMrubyCocos2dClassValue(mrb_state *mrb, const char* className) {
  mrb_value klass = mrb_iv_get(mrb, mrb_obj_value(mrb->kernel_module), mrb_intern_cstr(mrb, className));
  return klass;
}

static struct RClass* getMrubyCocos2dClassPtr(mrb_state *mrb, const char* className) {
  return mrb_class_ptr(getMrubyCocos2dClassValue(mrb, className));
}

template <class T>
mrb_value wrap(mrb_state *mrb, T* ptr, const char* type) {
  struct RClass* tc = getMrubyCocos2dClassPtr(mrb, type);
  mrb_value instance = mrb_obj_value(Data_Wrap_Struct(mrb, tc, &dummy_type, NULL));
  DATA_TYPE(instance) = &dummy_type;
  DATA_PTR(instance) = ptr;
  return instance;
}
EOD
  end

  def convert_constructors(klass, methods)
    methods.map do |method|
      if is_constructor?(method[0])
        flag, params = method
        [flag | STATIC, "#{klass}*", "__ctor", params]
      else
        method
      end
    end
  end

  def generate(filename, constants, classes, functions)
    put_header

    classes.each do |klass, info|
      methods = convert_constructors(klass, info[:methods])
      klass_methods = group_class_methods_by_name(methods)

      print <<EOD

////////////////////////////////////////////////////////////////
// #{klass}
EOD
      klass_methods.each do |method_name, methods|
        declare_methods(klass, method_name, methods)
      end

      parent = info.has_key?(:parent) ? info[:parent] : nil
      declare_class(klass, parent, klass_methods)
    end

      print <<EOD

////////////////////////////////////////////////////////////////
// Functions.
EOD

    functions.each do |return_type, func_name, params|
      declare_function(return_type, func_name, params)
    end

    puts ""
    puts "void install#{File.basename(filename, '.*')}(mrb_state *mrb, struct RClass *mod) {"

    register_constants(constants)

    # TODO: Define functions under module.
    puts "  struct RClass* tc = mrb->kernel_module;"
    functions.each do |return_type, func_name, params|
      puts %!  mrb_define_method(mrb, tc, "#{func_name}", #{func_name}__, MRB_ARGS_ANY());!
    end

    classes.each do |klass, _|
      puts "  install#{klass}(mrb, mod);"
    end

    puts "}"
  end

  def register_constants(constants)
    constants.each do |constant|
      register_constant(constant[0], constant[1])
    end
  end

  def register_constant(type, varname)
    puts <<EOD
  mrb_define_const(mrb, mod, "#{varname}", #{c_value_to_mruby_value(type, varname)});
EOD
  end

  def declare_function(return_type, func_name, params)
    declare_methods(nil, func_name, [[0, return_type, params]])
  end

  def declare_methods(klass, method_name, methods)
    flag = methods[0][0]
    if is_attr_accessor?(flag)
      declare_attr_accessor(klass, method_name, methods[0][1])  # Assumes attr_accessor does not have override methods.
      return
    end

    get_args = true
    if methods.size == 1
      get_arg_count = ''
      if methods[0][2].empty?
        get_args = false
      end
    end

    block_required = false
    methods.each do |_, _, params|
      block_required |= params.include?('block')
    end

    c_func_name = klass ? "#{klass}_#{method_name}" : "#{method_name}__"

    puts ""
    puts "static mrb_value #{c_func_name}(mrb_state *mrb, mrb_value self) {"
    if get_args
      if block_required
        print <<EOD
  mrb_value* args;
  int arg_count;
  mrb_value block;
  mrb_get_args(mrb, "*&", &args, &arg_count, &block);
EOD
      else
        print <<EOD
  mrb_value* args;
  int arg_count;
  mrb_get_args(mrb, "*", &args, &arg_count);
EOD
      end
    end

    if methods.size == 1
      flag, return_type, params = methods[0]
      declare_exec_method(klass, method_name, flag, return_type, params, 0);
    else
      methods.each_with_index do |method, i|
        flag, return_type, params = method
        block_required = params.include?('block')
        arg_count = params.size - (block_required ? 1 : 0)
        has_else = i == 0 ? '' : '} else '
        puts "  #{has_else}if (arg_count == #{arg_count}) {"
        declare_exec_method(klass, method_name, flag, return_type, params, 1);
      end
      print <<EOD
  } else {
    // TODO: raise exception.
    return mrb_nil_value();
  }
EOD
    end

    puts "}"
  end

  def declare_exec_method(klass, method_name, flag, return_type, params, indent)
    converted_params = []  # 0=type, 1=name, 2=value
    index = 0
    params.each do |type|
      a = if type == 'block'
            ['int', 'blockHandler', 'registerProc(mrb, block)']
          else
            i = index
            index += 1
            converter = mruby_value_to_c_value(type, "args[#{i}]")
            [type, "p#{i}", converter]
          end
      converted_params.push(a)
    end

    convert_params = converted_params.map {|type, name, val| "#{type} #{name} = #{val};"}
    cparams = converted_params.map {|_, name, _| name}.join(', ')

    if return_type != 'void'
      return_var = "#{return_type} retval = "
      return_stmt = "return #{c_value_to_mruby_value(return_type, 'retval')};"
    else
      return_var = ''
      return_stmt = 'return mrb_nil_value();'
    end

    if !klass
      get_instance = ''
      call_method = "#{method_name}"
    elsif is_constructor?(flag)
      get_instance = ''
      call_method = "new #{klass}"
      return_stmt = "DATA_PTR(self) = retval; return self;"
    elsif is_static?(flag)
      get_instance = ''
      call_method = "#{klass}::#{method_name}"
    else
      get_instance = "#{klass}* instance = static_cast<#{klass}*>(DATA_PTR(self));"
      call_method = "instance->#{method_name}"
    end

    str = <<EOD
#{convert_params.map {|s| "  #{s}"}.join("\n")}
  #{get_instance}
  #{return_var}#{call_method}(#{cparams});
  #{return_stmt}
EOD
    if indent == 0
      print str
      return
    end
    str.split("\n").each do |line|
      puts ("  " * indent) + line
    end
  end

  def declare_attr_accessor(klass, member_name, return_type)
    print <<EOD

static mrb_value #{klass}_#{member_name}(mrb_state *mrb, mrb_value self) {
  #{klass}* instance = static_cast<#{klass}*>(DATA_PTR(self));
  return #{c_value_to_mruby_value(return_type, "instance->#{member_name}")};
}

static mrb_value #{klass}_set_#{member_name}(mrb_state *mrb, mrb_value self) {
  mrb_value o;
  mrb_get_args(mrb, "o", &o);
  #{klass}* instance = static_cast<#{klass}*>(DATA_PTR(self));
  instance->#{member_name} = #{mruby_value_to_c_value(return_type, "o")};
  return mrb_nil_value();
}
EOD
  end

  def declare_class(klass, parent, methods)
    if parent
      get_parent = "getMrubyCocos2dClassPtr(mrb, \"#{parent}\")";
    else
      get_parent = 'mrb->object_class';
    end
    print <<EOD

static void install#{klass}(mrb_state *mrb, struct RClass *mod) {
  struct RClass* parent = #{get_parent};
  struct RClass* tc = mrb_define_class_under(mrb, mod, "#{klass}", parent);
  MRB_SET_INSTANCE_TT(tc, MRB_TT_DATA);
EOD
    methods.each do |method_name, methods|
      if is_constructor?(methods[0][0])
        puts %!  mrb_define_method(mrb, tc, "initialize", #{klass}_#{method_name}, MRB_ARGS_ANY());!
      elsif is_static?(methods[0][0]) && !is_constructor?(methods[0][0])
        puts %!  mrb_define_class_method(mrb, tc, "#{method_name}", #{klass}_#{method_name}, MRB_ARGS_ANY());!
      elsif is_attr_accessor?(methods[0][0])
        puts %!  mrb_define_method(mrb, tc, "#{method_name}", #{klass}_#{method_name}, MRB_ARGS_NONE());!
        puts %!  mrb_define_method(mrb, tc, "#{method_name}=", #{klass}_set_#{method_name}, MRB_ARGS_REQ(1));!
      else
        puts %!  mrb_define_method(mrb, tc, "#{method_name}", #{klass}_#{method_name}, MRB_ARGS_ANY());!
      end
    end
    puts "}"
  end

  def group_class_methods_by_name(methods)
    klass_methods = Hash.new{|h, k| h[k] = []}
    methods.each do |info|
      method_name = info[2]
      info = info.dup
      info.delete_at(2)
      klass_methods[method_name].push(info)
    end
    return klass_methods
  end

  def mruby_value_to_c_value(type, varname)
    case type
    when 'const char*'
      return "mrb_string_value_ptr(mrb, #{varname})"
    when 'bool'
      return "get_bool(#{varname})"
    when 'int'
      return "get_int(#{varname})"
    when 'float'
      return "get_float(#{varname})"
    when 'double'
      return "get_double(#{varname})"
    when 'block'
      return "get_bool(#{varname})"
    else
      plain_type = get_plain_type(type)
      if is_pointer_type(type)
        return "static_cast<#{plain_type}*>(DATA_PTR(#{varname}))"
      else
        return "*static_cast<#{plain_type}*>(DATA_PTR(#{varname}))"
      end
    end
  end

  def c_value_to_mruby_value(type, varname)
    case type
    when 'int'
      return "mrb_fixnum_value(#{varname})"
    when 'float'
      return "mrb_float_value(mrb, #{varname})"
    else
      plain_type = get_plain_type(type)
      if is_pointer_type(type)
        return %!wrap(mrb, #{varname}, "#{plain_type}")!
      else
        # TODO: Think other way to copy object.
        return %!wrap(mrb, new(mrb_malloc(mrb, sizeof(#{plain_type}))) #{plain_type}(#{varname}), "#{plain_type}")!
      end
    end
  end
end


if $0 == __FILE__
  filename = ARGV.shift || (raise "argv < 1")
  content = open(filename).read
  eval(content)

  gen = MrubyStubGenerator.new
  gen.generate(filename, Constants, Classes, Functions)
end

#