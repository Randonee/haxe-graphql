package graphql;

import graphql.ASTDefs;
import haxe.ds.Either;


@:enum abstract OutputTyping(String) {
  var TYPEDEFS = 'typedefs';
  var CLASSES = 'classes';
}

typedef HxGenOptions = {
  ?type:OutputTyping,
  ?null_wraps:Bool
}

// key String is field_name
typedef InterfaceType = haxe.ds.StringMap<TypeStringifier>;

@:expose
class HaxeGenerator
{
  private var _stdout_writer:StringWriter;
  private var _stderr_writer:StringWriter;
  private var _interfaces = new ArrayStringMap<InterfaceType>();
  private var _options:HxGenOptions;

  public static function parse(doc:Document,
                               ?options:HxGenOptions):{ stdout:String, stderr:String }
  {
    var gen = new HaxeGenerator(options);

    // Check for options / init errors
    if (gen._stderr_writer.is_empty()) {
      return { stdout:'', stderr:gen._stderr_writer.toString() };
    }

    return gen.parse_document(doc);
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
    if (_options.type==null) _options.type = TYPEDEFS;
    if (!(_options.null_wraps==false)) _options.null_wraps = true;
  }

  // Parse a graphQL AST document, generating Haxe code
  private function parse_document(doc:Document) {
    // Parse definitions
    init_base_types();

    // First pass: parse interfaces only
    // - when outputing typedefs, types will "> extend" interfaces, removing duplicate fields
    // - TODO: is this proper behavior? Or can type field be a super-set of the interface field?
    //         see spec: http://facebook.github.io/graphql/October2016/#sec-Object-type-validation
    //         "The object field must be of a type which is equal to or a sub‐type of the
    //          interface field (covariant)."
    for (def in doc.definitions) {
      switch (def.kind) {
        case ASTDefs.Kind.INTERFACE_TYPE_DEFINITION:
        write_interface_as_haxe_base_typedef(def);
      }
    }

    // Second pass: parse everything else
    for (def in doc.definitions) {
      switch (def.kind) {
      case ASTDefs.Kind.ENUM_TYPE_DEFINITION:
        write_haxe_enum(def);
      case ASTDefs.Kind.OBJECT_TYPE_DEFINITION:
        write_haxe_typedef(def);
      case ASTDefs.Kind.UNION_TYPE_DEFINITION:
        write_union_as_haxe_enum(def);
      case ASTDefs.Kind.INTERFACE_TYPE_DEFINITION:
        // Interfaces are a no-op in the second pass
      default:
        var name = def.name ? (' - '+def.name.value) : '';
        error('Error: unknown / unsupported definition kind: '+def.kind+name);
      }
    }

    return {
      stderr:_stderr_writer.toString(),
      stdout:_stdout_writer.toString()
    };
  }

  public function toString() return _stdout_writer.toString();

  private function error(s:String) _stderr_writer.append(s);

  private var referenced_types = [];
  function type_referenced(name) {
    if (referenced_types.indexOf(name)<0) referenced_types.push(name);
  }

  private var defined_types = [];
  function type_defined(name) {
    if (defined_types.indexOf(name)<0) defined_types.push(name);
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
  function write_haxe_typedef(def:ASTDefs.ObjectTypeDefinitionNode) {
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

    type_defined(def.name.value);
    for (field in def.fields) {
      // if (field.name.value=='id') debugger;
      var type = parse_type(field.type);
      var field_name = field.name.value;

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
          type_str = (outer_optional ? '?' : '') + field_name + ': '+type.toString(_options.null_wraps==true) + ',';
        } else {
          // Outer optional gets converted to @:optional
          type_str = (outer_optional ? '@:optional' : '') + 'var ' + field_name + ': ' + type.toString(_options.null_wraps==true) + ';';
        }
        _stdout_writer.append('  '+type_str);
      }
    }

    if (short_format) _stdout_writer.chomp_trailing_comma(); // Haxe doesn't care, but let's be tidy
    _stdout_writer.append('}');
  }

  function write_interface_as_haxe_base_typedef(def:ASTDefs.ObjectTypeDefinitionNode) {
    if (def.name==null || def.name.value==null) throw 'Expecting interface must have a name';
    var name = def.name.value;
    if (_interfaces.exists(name)) throw 'Duplicate interface named '+name;

    var intf = new ArrayStringMap<TypeStringifier>();
    for (field in def.fields) {
      var type = parse_type(field.type);
      var field_name = field.name.value;
      intf[field_name] = type;
    }

    _interfaces[name] = intf;

    // Generate the interface like a type
    write_haxe_typedef(def);
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

  function write_union_as_haxe_enum(def:ASTDefs.UnionTypeDefinitionNode) {
    // trace('Generating union (enum): '+def.name.value);
    type_defined(def.name.value);
    _stdout_writer.append('enum '+def.name.value+' { // Union');
    for (type in def.types) {
      if (type.name==null) throw 'Expecting Named Type';
      _stdout_writer.append('  is_'+type.name.value+'(value:'+type.name.value+');');
    }
    _stdout_writer.append('}');
  }

  // Init ID type as lenient abstract over String
  // TODO: optional require toIDString() for explicit string casting
  function init_base_types() {
    // ID
    _stdout_writer.append('/* - - - - Haxe / GraphQL compatibility types - - - - */');
    _stdout_writer.append('abstract IDString(String) to String { // Strict safety -- require explicit fromString');
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
    _stdout_writer.append('/* - - - - - - - - - - - - - - - - - - - - - - - - - */');
  }

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
}
typedef TSChildOrBareString = OneOf<TypeStringifier,String>;