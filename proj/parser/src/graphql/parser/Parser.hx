package graphql.parser;

import graphql.ASTDefs;

import tink.parse.ParserBase;
import tink.parse.Char.*;

using tink.CoreApi;

@:structInit
class Pos {
  public var file:String;
  public var min:Int;
  public var max:Int;
}

@:structInit
class Err {
  public var message:String;
  public var pos:Pos;
}

class Parser extends tink.parse.ParserBase<Pos, Err>
{
  public var document(default,null):Document;
  private var _filename:String;

  public function new(schema:String, filename:String='Untitled')
  {
    super(schema);
    _filename = filename;

    try {
      document = readDocument();
    } catch (e:Err) {
      format_and_rethrow(_filename, this.source, e);
    }
  }

  static function format_and_rethrow(filename:String, source:tink.parse.StringSlice, e:Err)
  {
    var line_num = 1;
    var off = 0;
    for (i in 0...e.pos.min) if (source.fastGet(i)=="\n".code) {
      off = i;
      line_num++;
    }
    // Line number error message
    var msg = '$filename:$line_num: characters ${ e.pos.min-off }-${ e.pos.max-off } Error: ${ e.message }';
    throw msg;
  }

  static var COMMENT_CHAR = '#'.code;

  private function readDocument()
  {
    var defs = [];
    while (true) {
      skipWhitespace(true);

      if (done()) break;

      switch readDefinition() {
        case Success(d):
          defs.push(d);
        case Failure(f):
          throw makeError(f.message, makePos(pos));
      }
    }
    return { definitions:defs };
  }

  private function readDefinition():Outcome<BaseNode, Err>
  {
    skipWhitespace(true);
    var p = pos;
    var rtn:Outcome<BaseNode, Err> = switch ident(true) {
      case Success(v) if (v=="type"): readTypeDefinition(p);
      case Success(v) if (v=="interface"): readTypeDefinition(p, true);
      case Success(v) if (v=="schema"): readTypeDefinition(p, false, true);
      case Success(v) if (v=="enum"): readEnumDefinition(p);
      case Success(v) if (v=="union"): readUnionDefinition(p);
      case Success(v) if (v=="scalar"): readScalarDefinition(p);
      case Success(_): Failure(makeError('Got "${ source[p...pos] }", expecting keyword: type interface enum schema union', makePos(p)));
      case Failure(e): Failure(e);
    }
    return rtn;
  }

  private function readTypeDefinition(start:Int,
                                      is_interface:Bool=false,
                                      is_schema:Bool=false):Outcome<BaseNode, Err> {
    var def = {
      loc: { start:start, end:start, source:_filename, startToken:null, endToken:null  },
      kind: Kind.OBJECT_TYPE_DEFINITION,
      name:null,
      fields:[]
    };
    if (is_interface) def.kind = Kind.INTERFACE_TYPE_DEFINITION;
    if (is_schema) def.kind = Kind.SCHEMA_DEFINITION;
    var interfaces = [];
    skipWhitespace(true);
    if (!is_schema) {
      var name = readNameNode();
      if (!name.isSuccess()) return Failure(name.getParameters()[0]);
      def.name = name.sure();
      skipWhitespace(true);
    }

    var err:Outcome<BaseNode, Err> = null;
    if (allow('implements')) {
      if (is_interface) return fail('Interfaces cannot implement interfaces.');
      parseRepeatedly(function():Void {
        var name = readNameNode();
        if (!name.isSuccess()) err = Failure(name.getParameters()[0]);
        var if_type:NamedTypeNode = { kind:Kind.NAMED_TYPE, name:name.sure() };
        interfaces.push(if_type);
      }, {end:'{', sep:'&', allowTrailing:false});
    } else {
      expect('{');
    }
    if (err!=null) return err;

    while (true) {
      switch readFieldDefinition() {
        case Success(field): def.fields.push(field);
        case Failure(e): return Failure(e);
      }
      if (allow('}')) break;
    }
    def.loc.end = pos;

    skipWhitespace(true);

    if (is_interface) {
      var inode:InterfaceTypeDefinitionNode = def;
      return Success(inode);
    } else if (is_schema) {
      // TODO: var snode:SchemaDefinitionNode = def;
      throw 'SchemaDefinitionNode is not yet supported...';
    } else {
      var onode:ObjectTypeDefinitionNode = {
        name:def.name, loc:def.loc, kind:def.kind, fields:def.fields, interfaces:interfaces
      };
      return Success(onode);
    }
  }

  private function readNameNode(skip_whitespace:Bool=true):Outcome<NameNode, Err>
  {
    if (skip_whitespace) skipWhitespace(true);
    var start = pos;
    return try {
      var name:String = ident().sure();
      var loc = { start:start, end:pos, source:_filename, startToken:null, endToken:null };
      Success({ kind:Kind.NAMED_TYPE, value:name, loc:loc });
    } catch (e:Dynamic) {
      Failure(makeError('Name identifier expected', makePos(pos)));  
    }
  }

  private function readEnumDefinition(start:Int):Outcome<BaseNode, Err>
  {
    var def:EnumTypeDefinitionNode = {
      loc: { start:start, end:pos, source:_filename, startToken:null, endToken:null },
      kind:Kind.ENUM_TYPE_DEFINITION,
      name:null,
      values:[]
    };

    var name = readNameNode();
    if (!name.isSuccess()) return Failure(name.getParameters()[0]);
    def.name = name.sure();
    skipWhitespace(true);

    expect('{');
    while (true) {
      var name = readNameNode();
      if (!name.isSuccess()) return Failure(name.getParameters()[0]);
      var ev:EnumValueDefinitionNode = { kind:Kind.NAMED_TYPE, name:name.sure() };
      def.values.push(ev);
      skipWhitespace(true);
      if (allow('}')) break;
    }
    def.loc.end = pos;

    skipWhitespace(true);
    return Success(def);
  }

  private function readScalarDefinition(start:Int):Outcome<BaseNode, Err>
  {
    var def:ScalarTypeDefinitionNode = {
      loc: { start:start, end:pos, source:_filename, startToken:null, endToken:null },
      kind:Kind.SCALAR_TYPE_DEFINITION,
      name:null
    };
    skipWhitespace(true);
    var name = readNameNode();
    if (!name.isSuccess()) return Failure(name.getParameters()[0]);
    def.name = name.sure();
    def.loc.end = pos;
    skipWhitespace(true);
    return Success(def);
  }

  private function readUnionDefinition(start:Int):Outcome<BaseNode, Err>
  {
    var def:UnionTypeDefinitionNode = {
      loc: { start:start, end:pos, source:_filename, startToken:null, endToken:null },
      kind:Kind.UNION_TYPE_DEFINITION,
      name:null,
      types:[]
    };
    var name = readNameNode();
    if (!name.isSuccess()) return Failure(name.getParameters()[0]);
    def.name = name.sure();
    skipWhitespace(true);

    expect('=');
    while (true) {
      var name = readNameNode();
      if (!name.isSuccess()) return Failure(name.getParameters()[0]);
      var u_type:NamedTypeNode = { kind:Kind.NAMED_TYPE, name:name.sure() };
      def.types.push(u_type);
      if (!allow('|')) break;
    }
    def.loc.end = pos;

    skipWhitespace(true);
    return Success(def);
  }

  private function readFieldDefinition()
  {
    skipWhitespace(true);
    var def:FieldDefinitionNode = {
      loc: { start:pos, end:pos, source:_filename, startToken:null, endToken:null },
      kind:Kind.OBJECT_TYPE_DEFINITION,
      name:null,
      type:null,
      arguments:[],
      directives:[]
    };

    var name = readNameNode();
    if (!name.isSuccess()) return Failure(name.getParameters()[0]);
    def.name = name.sure();

    if (allow('(')) {
      var args = readArguments();
      if (!args.isSuccess()) return Failure(args.getParameters()[0]);
      def.arguments = args.sure();
    }

    skipWhitespace();
    var type = readTypeNode();
    if (!type.isSuccess()) return Failure(type.getParameters()[0]);
    def.type = cast type.sure();

    def.loc.end = pos;
    skipWhitespace(true);
    return Success(def);
  }
  //function kwd(name:String) {
  //  var pos = pos;
  //  
  //  var found = switch ident(true) {
  //    case Success(v) if (v == name): true;
  //    default: false;
  //  }
  //  
  //  if (!found) this.pos = pos;
  //  return found;
  //}

  private function readTypeNode():Outcome<graphql.TypeNode, Err>
  {
    var list_wrap = false;
    var inner_not_null = false;
    var outer_not_null = false;

    expect(':');
    if (allow('[')) list_wrap = true;
    var name = readNameNode();
    if (!name.isSuccess()) return Failure(name.getParameters()[0]);
    var named_type:NamedTypeNode = { kind:Kind.NAMED_TYPE, name:name.sure() }
    skipWhitespace();
    if (list_wrap) {
      if (allow('!')) inner_not_null = true;
      skipWhitespace();
      expect(']');
    }
    skipWhitespace();
    if (allow('!')) outer_not_null = true;

    // Wrap the NamedTypeNode in List and/or NonNull wrappers
    var type:TypeNode = null;
    var ref:TypeNode = null;
    function update_ref(t:TypeNode) {
      if (type==null) {
        type = t;
        ref = t;
      } else {
        ref.type = t;
        ref = t;
      }
    }

    if (outer_not_null) update_ref(cast { type:null, kind:Kind.NON_NULL_TYPE });
    if (list_wrap) update_ref({ type:null, kind:Kind.LIST_TYPE });
    if (inner_not_null) update_ref({ type:null, kind:Kind.NON_NULL_TYPE } );
    update_ref(cast named_type);

    return Success(type);
  }

  private function readArguments():Outcome<Array<graphql.InputValueDefinitionNode>, Err>
  {
    var args = [];

    while (true) {
      var iv:graphql.InputValueDefinitionNode = {
        type : null, // graphql.TypeNode,
        name : null, // graphql.NameNode,
        loc : null, // Null<graphql.Location>,
        kind : Kind.INPUT_VALUE_DEFINITION, // String,
        directives : null,  // Null<graphql.ReadonlyArray<graphql.DirectiveNode>>,
        description : null, // Null<graphql.StringValueNode>,
        defaultValue : null // Null<graphql.ValueNode>
      };
      var name = readNameNode();
      if (!name.isSuccess()) return Failure(name.getParameters()[0]);
      iv.name = name.sure();

      skipWhitespace(true);
      var type = readTypeNode();
      if (!type.isSuccess()) return Failure(type.getParameters()[0]);
      iv.type = cast type.sure();

      args.push(iv);

      skipWhitespace(true);
      if (allow(')')) break;

      skipWhitespace(true);
      if (allow('=')) {
        var dv = readValue();
        if (!dv.isSuccess()) return Failure(dv.getParameters()[0]);
        iv.defaultValue = dv.sure();
      }

      skipWhitespace(true);
      if (allow(')')) break;
      expect(',');
    }

    return Success(args);
  }

  private function readValue():Outcome<ValueNode, Err>
  {
    //  typedef IntValueNode >  value: String,
    //  typedef FloatValueNode >  value: String,
    //  typedef StringValueNode >  value: String,  ?block: Bool,
    //  typedef BooleanValueNode >  value: Bool,
    //  typedef NullValueNode 
    //  typedef EnumValueNode >  value: String,
    //  typedef ListValueNode >  values: ReadonlyArray<ValueNode>,
    //  typedef ObjectValueNode > fields: ReadonlyArray<ObjectFieldNode>, // name:value

    skipWhitespace(true);

    var num = readNumeric();
    if (num!=null) {
      var v = {
        kind:num.is_float ? Kind.FLOAT : Kind.INT,
        value:num.value
      };
      return Success(cast v);
    }

    var str = readString();
    if (str!=null) {
      var v = { value:str.value, block:str.is_block };
      return Success(cast v);
    }

    if (allowHere('true')) return Success(cast { kind:Kind.BOOLEAN, value:true });
    if (allowHere('false')) return Success(cast { kind:Kind.BOOLEAN, value:false });
    if (allowHere('null')) return Success(cast { kind:Kind.NULL, value:false });
    if (is(IDENT_START)) return Success(cast { kind:Kind.ENUM, value:ident(true) });

    if (is('['.code)) return Success(cast { kind:Kind.LIST, values:readArrayValues() });
    if (is('{'.code)) return Success(cast { kind:Kind.OBJECT, fields:readObjectFields() });

    throw makeError('Expected value but found ${ source.get(pos) }', makePos(pos));
    return null;
  }

  private function readNumeric():Null<{ value:String, is_float:Bool}>
  {
    // http://facebook.github.io/graphql/draft/#sec-Int-Value
    var reset = pos;
    var negative = allowHere('-');
    var is_float = false;
    var num:String = readWhile(DIGIT);
    if (num==null || num.length==0) {
      pos = reset;
      return null;
    }
    if (negative) num = '-'+num;
    var dot = allowHere('.');
    if (dot) {
      is_float = true;
      num += '.';
      num += readWhile(DIGIT);
    }
    var exp = is(EXP) ? 'e' : null;
    if (exp!=null) {
      is_float = true;
      num += 'e'; pos++;
      var neg_exp = allowHere('-');
      var eval = readWhile(DIGIT);
      if (eval.length!=1) throw makeError('Invalid exponent ${ eval }', makePos(pos));
      num += (neg_exp ? '-' : '') + eval;
    }
    return { value:num, is_float:is_float };
  }

  private function readString():Null<{ value:String, is_block:Bool}>
  {
    // http://facebook.github.io/graphql/draft/#sec-String-Value
    var reset = pos;
    var is_quote = allowHere('"');
    if (!is_quote) {
      pos = reset;
      return null;
    }

    // TODO: Unicode? block strings?
    var is_block = allowHere('""');
    var last_char:Int = 0;
    var str = new StringBuf();

    while (true) {
      if (pos==source.length) throw makeError('Unterminated string', makePos(reset));
      var char = source.fastGet(pos++);

      // quote, test if it's an exit
      if (char=='"'.code) { // quote
        if (last_char!='\\'.code) { // not an escaped quote
          if (!is_block) break;
          // peek forward block break
          if (is_block && source.get(pos)=='"'.code && source.get(pos+1)=='"'.code) {
            pos = pos + 2;
            break;
          }
        }
      }
      last_char = char;
      // TODO: what about r f b?
      if (!is_block && char==13) str.add("\\n");
      else if (!is_block && char==9) str.add("\\t");
      else str.addChar(char);
    }

    return { value:str.toString(), is_block:is_block };
  }

  private function readArrayValues():Array<ValueNode>
  {
    var values = [];
    expect('[');
    if (allow(']')) return values;
    while(true) {
      var val = readValue();
      if (!val.isSuccess()) throw makeError(val.getParameters()[0], makePos(pos));
      values.push(val.sure());
      skipWhitespace(true);
      if (allow(']')) break;
      expect(',');
    }
    return values;
  }

  private function readObjectFields():Array<ObjectFieldNode>
  {
    var fields = [];
    expect('{');
    if (allow('}')) return fields;
    while (true) {
      skipWhitespace(true);
      var key = readString();
      if (key==null) throw makeError('Expecting object key', makePos(pos));
      if (key.is_block) throw makeError('Object keys don\'t support block strings', makePos(pos));
      skipWhitespace(true);
      expect(':');
      var val = readValue();
      if (!val.isSuccess()) throw makeError(val.getParameters()[0], makePos(pos));
      var nn:NameNode = { kind:Kind.NAME, value:key.value };
      var of:ObjectFieldNode = { kind:Kind.OBJECT_FIELD, name:nn, value:val.sure() };
      fields.push(of);
      if (allow('}')) break;
      expect(',');
    }
    return fields;
  }

  private inline function fail(msg) return Failure(makeError(msg, makePos(pos)));

  static var EXP = @:privateAccess tink.parse.Filter.ofConst('e'.code) || @:privateAccess tink.parse.Filter.ofConst('E'.code);
  static var IDENT_START = UPPER || LOWER || '_'.code;
  static var IDENT_CONTD = IDENT_START || DIGIT;

  private function ident(here = false) {
    return 
      if ((here && is(IDENT_START)) || (!here && upNext(IDENT_START)))
        Success(readWhile(IDENT_CONTD));
      else 
        Failure(makeError('Identifier expected', makePos(pos)));  
  }

  private inline function skipWhitespace(and_comments:Bool=false) {
    doReadWhile(WHITE);
    if (and_comments) {
      while (true) {
        if (is(COMMENT_CHAR)) { upto("\n"); } else { break; }
        doReadWhile(WHITE);
      }
    }
  }

  override function doSkipIgnored() skipWhitespace();
  
  override function doMakePos(from:Int, to:Int):Pos
  {
    return { file:'Untitled', min:from, max:to };
  }

  override function makeError(message:String, pos:Pos):Err
  {
    return { message:message, pos:pos };
  }
}
