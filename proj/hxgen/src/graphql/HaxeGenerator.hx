package graphql;

import graphql.ASTDefs;
import haxe.ds.Either;

using Lambda;

@:enum abstract GenerateOption(String) {
  var TYPEDEFS = 'typedefs';
  var CLASSES = 'classes';
}

typedef HxGenOptions = {
  ?generate:GenerateOption,
  ?disable_null_wrappers:Bool
}

typedef SchemaMap = {
  query_type:String,
  mutation_type:String
}

// key String is field_name
typedef InterfaceType = haxe.ds.StringMap<TypeStringifier>;

typedef SomeNamedNode = { kind:String, name:NameNode };

@:expose
class HaxeGenerator
{
  private var _stdout_writer:StringWriter;
  private var _stderr_writer:StringWriter;
  private var _interfaces = new ArrayStringMap<InterfaceType>();
  private var _options:HxGenOptions;

  public static function parse(doc:DocumentNode,
                               ?options:HxGenOptions,
                               throw_on_error=true):{ stdout:String, stderr:String }
  {
    var result = { stdout:'', stderr:'' };

    // Check for options / init errors
    var gen = new HaxeGenerator(options);
    if (!gen._stderr_writer.is_empty()) {
      result.stderr = gen._stderr_writer.toString();
    } else {
      result = gen.parse_document(doc);
    }

    if (throw_on_error && result.stderr.length>0) {
      throw result.stderr;
    }

    return result;
  }

  // Private constructor simply because, once parsed, the generator's state
  // is "dirty", it should be considered "consumed". So use a static
  // helper (above).
  private function new(?options:HxGenOptions)
  {
    _stdout_writer = new StringWriter();
    _stderr_writer = new StringWriter();
    init_options(options);
  }

  private function init_options(?options:HxGenOptions)
  {
    _options = options==null ? {} : options;
    if (_options.generate==null) _options.generate = TYPEDEFS;
    if (_options.disable_null_wrappers==null) _options.disable_null_wrappers = false;
  }

  private function handle_args(type_path:Array<String>, args:FieldArguments) {
    if (args==null || args.length==0) return;
    for (a in args) {
      var args_name = 'Args_${ type_path.join('Dot') }_${ a.field }';
      var args_obj:ObjectTypeDefinitionNode = {
        kind:Kind.OBJECT_TYPE_DEFINITION,
        name:{ value:args_name, kind:Kind.NAME },
        fields:cast a.arguments
      };
      write_haxe_typedef(args_obj);
    }
  }

  // Parse a graphQL AST document, generating Haxe code
  private function parse_document(doc:DocumentNode) {
    // Parse definitions
    init_base_types();

    function newline() _stdout_writer.append('');

    var root_schema:SchemaMap = null;

    // First pass: parse interfaces and schema def only
    // - when outputing typedefs, types will "> extend" interfaces, removing duplicate fields
    // - TODO: is this proper behavior? Or can type field be a super-set of the interface field?
    //         see spec: http://facebook.github.io/graphql/October2016/#sec-Object-type-validation
    //         "The object field must be of a type which is equal to or a sub‐type of the
    //          interface field (covariant)."
    for (def in doc.definitions) {
      switch (def.kind) {
        case ASTDefs.Kind.INTERFACE_TYPE_DEFINITION:
          var args = write_interface_as_haxe_base_typedef(cast def);
          newline();
          handle_args([get_def_name(cast def)], args);
        case ASTDefs.Kind.SCHEMA_DEFINITION:
          if (root_schema!=null) error('Error: cannot specify two schema definitions');
          root_schema = write_schema_def(cast def);
          newline();
        case _:
      }
    }

    // Second pass: parse everything else
    for (def in doc.definitions) {
      switch (def.kind) {
      case ASTDefs.Kind.SCHEMA_DEFINITION:
        // null op, handled above
      case ASTDefs.Kind.SCALAR_TYPE_DEFINITION:
        write_haxe_scalar(cast def);
        newline();
      case ASTDefs.Kind.ENUM_TYPE_DEFINITION:
        write_haxe_enum(cast def);
        newline();
      case ASTDefs.Kind.OBJECT_TYPE_DEFINITION:
        var args = write_haxe_typedef(cast def);
        newline();
        handle_args([get_def_name(cast def)], args);
      case ASTDefs.Kind.UNION_TYPE_DEFINITION:
        write_union_as_haxe_abstract(cast def);
        newline();
      case ASTDefs.Kind.OPERATION_DEFINITION:
        // No-op, still generating type map
      case ASTDefs.Kind.INTERFACE_TYPE_DEFINITION:
        // Interfaces are a no-op in the second pass
      default:
        var name = (cast def).name!=null ? (' - '+(cast def).name.value) : '';
        error('Error: unknown / unsupported definition kind: '+def.kind+name);
      }
    }

    // Third pass: write operation results
    for (def in doc.definitions) switch def.kind {
      case ASTDefs.Kind.OPERATION_DEFINITION:
        write_operation_def_result(root_schema, doc, cast def);
        newline();
      default:
    }

    return {
      stderr:_stderr_writer.toString(),
      stdout:_stdout_writer.toString()
    };
  }

  private function get_def_name(def) return def.name.value;

  public function toString() return _stdout_writer.toString();

  private function error(s:String) _stderr_writer.append(s);

  private var referenced_types = [];
  function type_referenced(name) {
    if (referenced_types.indexOf(name)<0) referenced_types.push(name);
  }

  private var defined_types = [];
  private var type_map = new ArrayStringMap<{ name:String, ?fields:ArrayStringMap<TypeStringifier> }>();
  function type_defined(name:String, fields:ArrayStringMap<TypeStringifier>=null) {
    if (defined_types.indexOf(name)<0) defined_types.push(name);
    type_map[name] = { name:name, fields:fields };
  }

  function parse_type(type:ASTDefs.TypeNode, parent:ASTDefs.TypeNode=null):TypeStringifier {
    var is_array = type.kind == ASTDefs.Kind.LIST_TYPE;
    var non_null = type.kind == ASTDefs.Kind.NON_NULL_TYPE;
    var wrapper = non_null || is_array;

    var optional = non_null ? false : (parent==null || parent.kind!=ASTDefs.Kind.NON_NULL_TYPE);
    var rtn:TypeStringifier = { prefix:'', suffix:'', child:null, optional:false };

    if (!wrapper) { // Leaf
      if (type.name==null) throw 'Expecting type.name!';
      if (type.type!=null) throw 'Not expecting recursive type!';
      if (type.kind!=ASTDefs.Kind.NAMED_TYPE) throw 'Expecting NamedType!';
      type_referenced(type.name.value);
      rtn.optional = optional;
      rtn.child = type.name.value;
    } else {
      if (type.type==null) throw 'Expecting recursive / wrapped type!';
      rtn.optional = optional;
      if (is_array) { rtn.prefix += 'Array<'; rtn.suffix += '>'; }
      rtn.child = parse_type(type.type, type);
    }

    return rtn;
  }

  /* -- TODO: REVIEW: http://facebook.github.io/graphql/October2016/#sec-Object-type-validation
                      sub-typing seems to be allowed... */
  function type0_equal_to_type1(type0:TypeStringifier, type1:TypeStringifier):Bool
  {
    // trace('STC: '+type0.toString(true)+' == '+type1.toString(true));
    return type0.toString(true)==type1.toString(true);
  }

  /**
   * @param {GraphQL.ObjectTypeDefinitionNode} def
   */
  function write_haxe_typedef(def:ASTDefs.ObjectTypeDefinitionNode):FieldArguments
  {
    var args:FieldArguments = [];

    // TODO: cli args for:
    //  - long vs short typedef format
    var short_format = true;

    // trace('Generating typedef: '+def.name.value);
    _stdout_writer.append('typedef '+def.name.value+' = {');

    var interface_fields_from = new ArrayStringMap<String>();
    var skip_interface_fields = new ArrayStringMap<TypeStringifier>();
    if (def.interfaces!=null) {
      for (intf in def.interfaces) {
        var ifname = intf.name.value;
        if (!_interfaces.exists(ifname)) throw 'Requested interface '+ifname+' (implemented by '+def.name.value+') not found';
        var intf = _interfaces[ifname];
        _stdout_writer.append('  /* implements interface */ > '+ifname+',');
        for (field_name in intf.keys()) {
          if (!skip_interface_fields.exists(field_name)) {
            skip_interface_fields[field_name] = intf.get(field_name);
            interface_fields_from[field_name] = ifname;
          } else {
            // Two interfaces could imply the same field name... in which
            // case we need to ensure the "more specific" definition is kept.
            if (!type0_equal_to_type1(intf.get(field_name), skip_interface_fields[field_name])) {
              throw 'Type '+def.name.value+' inherits field '+field_name+' from multiple interfaces ('+ifname+', '+interface_fields_from[field_name]+'), the types of which do not match.';
            }
          }
        }
      }
    }

    var fields = new ArrayStringMap<TypeStringifier>();
    type_defined(def.name.value, fields);

    for (field in def.fields) {
      // if (field.name.value=='id') debugger;
      var type = parse_type(field.type);
      var field_name = field.name.value;
      fields[field_name] = type.clone().follow();

      if (field.arguments!=null && field.arguments.length>0) {
        args.push({ field:field_name, arguments:field.arguments });
      }

      if (skip_interface_fields.exists(field_name)) {
        // Field is inherited from an interface, ensure the types match
        if (!type0_equal_to_type1(type, skip_interface_fields.get(field_name))) {
          throw 'Type '+def.name.value+' defines '+field_name+':'+type.toString(true)+', but Interface '+interface_fields_from[field_name]+' requires '+field_name+':'+interface_fields_from[field_name].toString();
        }
      } else {
        // Not inherited from an interface, include it in this typedef
        var type_str = '';
        var outer_optional = type.optional;
        type.optional = false;
        if (short_format) {
          // Outer optional gets converted to ?
          type_str = (outer_optional ? '?' : '') + field_name + ': '+type.toString(_options.disable_null_wrappers==true) + ',';
        } else {
          // Outer optional gets converted to @:optional
          type_str = (outer_optional ? '@:optional' : '') + 'var ' + field_name + ': ' + type.toString(_options.disable_null_wrappers==true) + ';';
        }
        _stdout_writer.append('  '+type_str);
      }
    }

    if (short_format) _stdout_writer.chomp_trailing_comma(); // Haxe doesn't care, but let's be tidy
    _stdout_writer.append('}');

    return args;
  }

  function write_interface_as_haxe_base_typedef(def:ASTDefs.ObjectTypeDefinitionNode):FieldArguments
  {
    var args:FieldArguments = [];

    if (def.name==null || def.name.value==null) throw 'Expecting interface must have a name';
    var name = def.name.value;
    if (_interfaces.exists(name)) throw 'Duplicate interface named '+name;

    var intf = new ArrayStringMap<TypeStringifier>();
    for (field in def.fields) {
      var type = parse_type(field.type);
      var field_name = field.name.value;
      intf[field_name] = type;

      if (field.arguments!=null && field.arguments.length>0) {
        args.push({ field:field_name, arguments:field.arguments });
      }
    }

    _interfaces[name] = intf;

    // Generate the interface like a type
    write_haxe_typedef(def);

    return args;
  }

  function write_haxe_enum(def:ASTDefs.EnumTypeDefinitionNode) {
    // trace('Generating enum: '+def.name.value);
    type_defined(def.name.value);
    _stdout_writer.append('enum '+def.name.value+' {');
    for (enum_value in def.values) {
      _stdout_writer.append('  '+enum_value.name.value+';');
    }
    _stdout_writer.append('}');
  }

  function write_haxe_scalar(def:ASTDefs.ScalarTypeDefinitionNode) {
    // trace('Generating scalar: '+def.name.value);
    type_defined(def.name.value);
    _stdout_writer.append('/* scalar ${ def.name.value } */\nabstract ${ def.name.value }(Dynamic) { }');
  }

  function write_union_as_haxe_abstract(def:ASTDefs.UnionTypeDefinitionNode) {
    // trace('Generating union (enum): '+def.name.value);
    type_defined(def.name.value);
    var union_types_note = def.types.map(function(t) return t.name.value).join(" | ");
    _stdout_writer.append('/* union '+def.name.value+' = ${ union_types_note } */');
    _stdout_writer.append('abstract '+def.name.value+'(Dynamic) {');
    for (type in def.types) {
      if (type.name==null) throw 'Expecting Named Type';
      var type_name = type.name.value;
      type_referenced(def.name.value);
      _stdout_writer.append(' @:from static function from${ type_name }(v:${ type_name }) return cast v;');
    }
    _stdout_writer.append('}');
  }

  // A schema definition is just a mapping / typedef alias to specific types
  function write_schema_def(def:ASTDefs.SchemaDefinitionNode):SchemaMap {
    var rtn = { query_type:null, mutation_type:null };

    _stdout_writer.append('/* Schema: */');
    for (ot in def.operationTypes) {
      var op = Std.string(ot.operation);
      switch op {
        case "query" | "mutation": //  | "subscription": is "non-spec experiment"
        var capitalized = op.substr(0,1).toUpperCase() + op.substr(1);
        _stdout_writer.append('typedef Schema${ capitalized }Type = ${ ot.type.name.value };');
        if (op=="query") rtn.query_type = ot.type.name.value;
        if (op=="mutation") rtn.mutation_type = ot.type.name.value;
        default: throw 'Unexpected schema operation: ${ op }';
      }
    }

    return rtn;
  }

  //function get_obj_of(named_things:Array<Dynamic>, find_name:String, parent_name:String=null) {
  //  for (thing in named_things) {
  //    if (thing.name!=null && thing.name.value==find_name) {
  //      return thing;
  //    }
  //  }
  //  throw 'Didn\'t find a ${ find_name } inside ${ parent_name }';
  //  return null;
  //}
//
  //function resolve_type_path(names:Array<String>, at:SomeNamedNode, root:SomeNamedNode, throw_node=false):String
  //{
  //  function expect_descent(parent, named_things) {
  //    var parent_name = parent.name==null ? 'Unknown' : parent.name.value;
  //    if (names.length==0) {
  //      if (throw_node) {
  //        throw parent;
  //      } else {
  //        throw 'Found type node ${ parent_name } but GraphQL requires specifying leaf types.';
  //      }
  //    }
  //    var next_root = get_obj_of(named_things, names[0], parent_name);
  //    var next_names = names.slice(1);
//
  //    if (next_names.length==0 &&
  //        (next_root.kind==Kind.SCALAR_TYPE_DEFINITION ||
  //        (next_root.kind==Kind.ENUM_TYPE_DEFINITION))) return next_root.name.value;
//
  //    var last_next_root = next_root;
  //    if (next_root.fields==null) {
  //      // Need name (could be wrapper in non-null and/or list)
  //      var name:NameNode = next_root.type.name;
  //      if (name==null) name = next_root.type.type.name;
  //      if (name==null) name = next_root.type.type.type.name;
  //      if (name==null) name = next_root.type.type.type.type.name;
  //      next_names.unshift(name.value);
  //      next_root = cast root;
  //    }
  //    return resolve_type_path(next_names, next_root, root, throw_node);
  //  }
//
  //  if (names.length==1) switch names[0] {
  //    case a if (a=='String' || a=='Int' || a=='ID' || a=='Boolean' || a=='Float'):
  //    return a;
  //  }
//
  //  return switch at.kind {
  //    case ASTDefs.Kind.SCALAR_TYPE_DEFINITION | ASTDefs.Kind.ENUM_TYPE_DEFINITION | ASTDefs.Kind.UNION_TYPE_DEFINITION:
  //      if (names.length>0) throw 'Cannot descend [${ names.join(",") }] into ${ at.kind }';
  //      at.name.value;
  //    case ASTDefs.Kind.OBJECT_TYPE_DEFINITION:    expect_descent(at, (cast at).fields);
  //    case ASTDefs.Kind.INTERFACE_TYPE_DEFINITION: expect_descent(at, (cast at).fields);
  //    case ASTDefs.Kind.DOCUMENT:                  expect_descent(at, (cast at).definitions);
  //    case _:
  //      throw 'Hmm, does resolve_type_path expect ${ at.kind } ???';
  //  }
  //}

  function resolve_type_path(path:Array<String>):ResolvedTypePath
  {
    var ptr:{ name:String, ?fields:ArrayStringMap<TypeStringifier> } = null;

    function array_inner_type(ts:TypeStringifier):String return switch ts.child {
      case Left(cts): cts.toString();
      default: null;
    } 

    var orig_path = path.join('.');
    var last_ts = null;
    while (path.length>0) {
      var name = path.shift();
      if (ptr==null) {
        ptr = type_map.get(name);
        if (ptr==null) throw 'Didn\'t find root type ${ name }';
      } else {
        if (ptr.fields==null) throw 'Expecting ${ ptr.name } to have fields --> ${ name }!';
        var ts = ptr.fields.get(name);
        if (ts==null) throw 'Expecting ${ ptr.name } to have field ${ name }!';
        ts = ts.follow();
        last_ts = ts;
        if (path.length==0) break;
        var nm:String = ts.child;
        if (ts.prefix.indexOf('Array')>=0) nm = array_inner_type(ts);
        if (nm==null) throw 'Expecting ts to have a name child -- is that not right?';
        ptr = type_map.get(nm);
        if (ptr==null) throw 'Didn\'t find expected root type ${ nm }';
      }
    }

    // trace('Looking for ${ orig_path }, last_ts was ${ last_ts }');

    var is_list = last_ts.prefix.indexOf('Array')>=0;
    var is_opt = last_ts.optional;
    var type_string:String = is_list ? array_inner_type(last_ts) : last_ts.toString();

    var resolved = type_map[type_string];
    if (resolved==null) throw 'Resolved ${ orig_path } to unknown type ${ type_string }';
    if (resolved.fields==null) {
      return LEAF(type_string, is_opt);
    } else {
      return TYPE(type_string, is_opt, is_list);
    }
  }

  function write_operation_def_result(root_schema:SchemaMap,
                                      root:ASTDefs.DocumentNode,
                                      def:ASTDefs.OperationDefinitionNode):Void
  {
    _stdout_writer.append('/* Operation def: */');

    if (def.operation!='query') throw 'Only OperationDefinitionNodes of type query are supported...';
    if (def.name==null || def.name.value==null) throw 'Only named queries are supported...';

    var op_name = def.name.value;
    // _stdout_writer.append('typedef ${ op_name }_Result = Dynamic; /* TODO !! */');

    var types:haxe.DynamicAccess<Dynamic> = {};

    // trace('HI');
    // trace('Resolve_scalar: Query: '+resolve_type_path(['Query', 'hero', 'name']));
    // trace('Resolve_scalar: Query: '+resolve_type_path(['Query', 'hero', 'id']));
    // trace('Resolve_scalar: Query: '+resolve_type_path(['Query', 'hero', 'born']));
    // // Throws, as expected -- must specify sub-fields of friends (Character)
    // trace('Resolve_scalar: Query: '+resolve_type_path(['Query', 'hero', 'friends']));
    // trace('Resolve_scalar: Query: '+resolve_type_path(['Query', 'hero', 'friends', 'name']));


    function handle_selection_set(sel_set:{ selections:Array<SelectionNode> },
                                  type_path:Array<String>, // always abs
                                  indent=1) {
      if (sel_set==null || sel_set.selections==null) {
        // Nothing left to do...
      }
 
      var ind:String = '';
      for (i in 0...indent) ind += '  ';

      // Always resolve names from root?
      //var base_type:String = resolve_type_path(names, cast root);
      for (sel_node in sel_set.selections) {
        switch (sel_node.kind) { // FragmentSpead | Field | InlineFragment
          case Kind.FIELD:
            var field_node:FieldNode = cast sel_node;

            var name:String = field_node.name.value;
            var alias:String = field_node.alias==null ? name : field_node.alias.value;

            var next_type_path = type_path.slice(0);
            next_type_path.push(name);
            switch resolve_type_path(next_type_path) {
              case ROOT: throw 'Type path ${ type_path.join(",") } in query ${ op_name } should not resolve to root!';
              case LEAF(str, opt):
                if (field_node.selectionSet!=null) throw 'Cannot specify sub-fields of ${ str } in ${ type_path.join(",") } of operation ${ op_name }';
                var prefix = ind + (opt ? "?" : "");
                _stdout_writer.append('${ prefix }${ alias }:${ str },');
              case TYPE(str, opt, list):
                if (field_node.selectionSet==null) throw 'Must specify sub-fields of ${ str } in ${ type_path.join(",") } of operation ${ op_name }';
                var prefix = ind + (opt ? "?" : "");
                var suffix1 = (list ? 'Array<{' : '{') + ' /* subset of ${ str } */';
                var suffix2 = (list ? '}>' : '}');
                _stdout_writer.append('$prefix$alias:$suffix1');
                handle_selection_set(field_node.selectionSet, [ str ], indent+1);
                _stdout_writer.append('$ind$suffix2');
            }

          default: throw 'Unhandled SelectionNode kind: ${ sel_node.kind } (TODO: FragmentSpread InlineFragment)';
        }
      }
    }
 
    var query_root_name = (root_schema==null || root_schema.query_type==null) ? 'Query' : root_schema.query_type;
    // var query_root = get_obj_of(root.definitions, query_root, 'Document');

    _stdout_writer.append('typedef QueryResult_${ op_name } = {');
    handle_selection_set(def.selectionSet, [ query_root_name ]);
    _stdout_writer.append('}');
  }

  // Init ID type as lenient abstract over String
  // TODO: optional require toIDString() for explicit string casting
  function init_base_types() {
    // ID
    _stdout_writer.append('/* - - - - Haxe / GraphQL compatibility types - - - - */');
    _stdout_writer.append('abstract IDString(String) to String {\n  // Strict safety -- require explicit fromString');
    _stdout_writer.append('  public static inline function fromString(s:String) return cast s;');
    _stdout_writer.append('  public static inline function ofString(s:String) return cast s;');
    _stdout_writer.append('}');
    _stdout_writer.append('typedef ID = IDString;');
    type_defined('ID');

    // Compatible with Haxe
    type_defined('String');
    type_defined('Float');
    type_defined('Int');

    // Aliases for Haxe
    _stdout_writer.append('typedef Boolean = Bool;');
    type_defined('Boolean');
    _stdout_writer.append('/* - - - - - - - - - - - - - - - - - - - - - - - - - */\n\n');
  }

}

enum ResolvedTypePath {
  ROOT;
  LEAF(str:String, optional:Bool);
  TYPE(str:String, optional:Bool, is_list:Bool);
}

class StringWriter
{
  private var _output:Array<String>;
  public function new()
  {
    _output = [];
  }
  public function is_empty() { return _output.length==0; }

  public function append(s) { _output.push(s); }

  // Remove trailing comma from last String
  public function chomp_trailing_comma() {
    _output[_output.length-1] = ~/,$/.replace(_output[_output.length-1], '');
  }

  public function toString() return _output.join("\n");

}

/*
 * GraphQL represents field types as nodes, with lists and non-nullables as
 * parent nodes. So we have a recursive structure to capture that idea:
 *
 * `type SomeList {`
 * `  items: [SomeItem!]`
 * `}`
 *
 * The type of items in AST nodes is:
 *
 *   `ListNode { NonNullNode { NamedTypeNode } }`
 *
 * TypeStringifier knows how to build a string out of this recursive structure,
 * so it gets converted to Haxe as: `Null<Array<SomeItem>>`, or if you choose
 * not to print the nulls, `Array<SomeItem>`, or as a field on a short-hand
 * typedef `?items:Array<SomeItem>` or as a field on a long-hand typedef:
 *
 *   `@:optional var items:Array<SomeItem>`
 */
@:structInit // allows assignment from anon structure with necessary fields
private class TypeStringifier
{
  public var prefix:String;
  public var suffix:String;
  public var optional:Bool;
  public var child:TSChildOrBareString;

  public function new(child:TSChildOrBareString,
                      optional=false,
                      prefix:String='',
                      suffix:String='')
  {
    this.child = child;
    this.prefix = prefix;
    this.suffix = suffix;
    this.optional = optional;
  }

  public function toString(optional_as_null=false) {
    var result = this.prefix + (switch child {
      case Left(ts): ts.toString(optional_as_null);
      case Right(str): str;
    }) + this.suffix;
    if (optional_as_null && this.optional) result = 'Null<' + result + '>';
    return result;
  }

  public function clone():TypeStringifier
  {
    var sheep = new TypeStringifier( switch this.child {
      case Left(ts): ts.clone();
      case Right(str): str;
    });
    sheep.optional = this.optional;
    sheep.prefix = this.prefix;
    sheep.suffix = this.suffix;
    return sheep;
  }

  public function follow():TypeStringifier
  {
    return switch this.child {
      case Right(str): this; // no follow necessary/possible
      case Left(ts):
      if (this.prefix=="" && this.suffix=="") {
        if (this.optional==true) {
          throw 'Do we get to this case? Can we not simply push optional to child?';
          // Push optional down to child and continue
          ts.optional = true;
          return ts.follow();
        }
        return ts.follow();
      }
      this.child = ts.follow(); // collapse children too
      return this;
    }
  }
}
typedef TSChildOrBareString = OneOf<TypeStringifier,String>;

typedef FieldArguments = Array<{
  field:String,
  arguments:Array<InputValueDefinitionNode>
}>
