#!/usr/bin/ruby

VERSION_TAG = "v0.13.2"
url = "https://raw.githubusercontent.com/graphql/graphql-js/#{ VERSION_TAG }/src/language/ast.js"

# Local for development...
url = "http://127.0.0.1/ast.js"
javascript = `curl --silent '#{ url }'`

haxe = javascript

haxe.gsub!(/export type/, "typedef /* export type */")
haxe.gsub!(/(\w+)\?:(\s+\?)?/, "?\\1 /* opt */ :")

# Basic types
haxe.gsub!(/:\s*boolean\b/, ":Bool")
haxe.gsub!(/:\s*string\b/, ":String")
haxe.gsub!(/:\s*number\b/, ":Int /* number */")

# Remove lading + signs
haxe.gsub!(/^(\s+)\+/, "\\1")

# Replace node unions with BaseNode
haxe.gsub!(/Node =(\s*\n\s+\|.*?;)/m, "Node = BaseNode; /* \\1 */")
haxe.gsub!(/Node = (\w+\s+\|.*?;)/, "Node = BaseNode; /* \\1 */")

haxe.gsub!(/\bNamedTypeNode \| ListTypeNode\b/, "TypeNode /* NamedTypeNode | ListTypeNode */")
haxe.gsub!(/^(typedef .*? TypeNode .*)/, "// \\1")

haxe.gsub!(/^\s+(prev|next):\s*Token \| null/, "  ?\\1: Null<Token>")
haxe.gsub!(/value:String \| void/, "?value:Null<String>")

# Comment out imports
haxe.gsub!(/^(import type .*)/, "// \\1")

# Kind string consts
haxe.gsub!(/kind: ('\w+')/, "kind: String, // \\1")

haxe.gsub!(/\$ReadOnlyArray/, "/* $ReadOnlyArray */Array");

op_type = <<eof
@:enum abstract OperationTypeNode(String) to String from String {
  var QUERY = 'query';
  var MUTATION = 'mutation';
  var SUBSCRIPTION = 'subscription'; // experimental non-spec
}
eof

haxe.gsub!(/(typedef .*? OperationTypeNode.*)/, "//  \\1 \n#{ op_type }")

# - - - -  write output
puts <<eof
package graphql;

/* GENERATED BY gen_ast.rb -- DO NOT EDIT!!! */
/* GENERATED BY gen_ast.rb -- DO NOT EDIT!!! */
/* GENERATED BY gen_ast.rb -- DO NOT EDIT!!! */
/* GENERATED BY gen_ast.rb -- DO NOT EDIT!!! */
/* */
/* based on: #{ url } */
/* */

typedef TokenKindEnum = TokenKind;

typedef Source = tink.parse.StringSlice;

typedef BaseNode = {
  kind:String,
  ?loc:Location
}

// Type nodes -- kind of a lie, but meh
typedef TypeNode = { > BaseNode,
  // Calling these optionals makes us able to simply null-check them:
  ?name: NameNode, // Only for NamedTypeNode
  ?type: TypeNode, // Not for NamedTypeNode
}

// typedef NamedOrListTypeNode = BaseNode; //  NamedTypeNode | ListTypeNode

// TokenKind
@:enum abstract TokenKind(String) to String from String {
  var SOF = '<SOF>';
  var EOF = '<EOF>';
  var BANG = '!';
  var DOLLAR = '$';
  var AMP = '&';
  var PAREN_L = '(';
  var PAREN_R = ')';
  var SPREAD = '...';
  var COLON = ':';
  var EQUALS = '=';
  var AT = '@';
  var BRACKET_L = '[';
  var BRACKET_R = ']';
  var BRACE_L = '{';
  var PIPE = '|';
  var BRACE_R = '}';
  var NAME = 'Name';
  var INT = 'Int';
  var FLOAT = 'Float';
  var STRING = 'String';
  var BLOCK_STRING = 'BlockString';
  var COMMENT = 'Comment';
}

// Kind
@:enum abstract Kind(String) to String from String {
  // Name
  var NAME = 'Name';

  // Document
  var DOCUMENT = 'Document';
  var OPERATION_DEFINITION = 'OperationDefinition';
  var VARIABLE_DEFINITION = 'VariableDefinition';
  var VARIABLE = 'Variable';
  var SELECTION_SET = 'SelectionSet';
  var FIELD = 'Field';
  var ARGUMENT = 'Argument';

  // Fragments
  var FRAGMENT_SPREAD = 'FragmentSpread';
  var INLINE_FRAGMENT = 'InlineFragment';
  var FRAGMENT_DEFINITION = 'FragmentDefinition';

  // Values
  var INT = 'IntValue';
  var FLOAT = 'FloatValue';
  var STRING = 'StringValue';
  var BOOLEAN = 'BooleanValue';
  var NULL = 'NullValue';
  var ENUM = 'EnumValue';
  var LIST = 'ListValue';
  var OBJECT = 'ObjectValue';
  var OBJECT_FIELD = 'ObjectField';

  // Directives
  var DIRECTIVE = 'Directive';

  // Types
  var NAMED_TYPE = 'NamedType';
  var LIST_TYPE = 'ListType';
  var NON_NULL_TYPE = 'NonNullType';
  
  // Type System Definitions
  var SCHEMA_DEFINITION = 'SchemaDefinition';
  var OPERATION_TYPE_DEFINITION = 'OperationTypeDefinition';
  
  // Type Definitions
  var SCALAR_TYPE_DEFINITION = 'ScalarTypeDefinition';
  var OBJECT_TYPE_DEFINITION = 'ObjectTypeDefinition';
  var FIELD_DEFINITION = 'FieldDefinition';
  var INPUT_VALUE_DEFINITION = 'InputValueDefinition';
  var INTERFACE_TYPE_DEFINITION = 'InterfaceTypeDefinition';
  var UNION_TYPE_DEFINITION = 'UnionTypeDefinition';
  var ENUM_TYPE_DEFINITION = 'EnumTypeDefinition';
  var ENUM_VALUE_DEFINITION = 'EnumValueDefinition';
  var INPUT_OBJECT_TYPE_DEFINITION = 'InputObjectTypeDefinition';
  
  // Type Extensions
  var SCALAR_TYPE_EXTENSION = 'ScalarTypeExtension';
  var OBJECT_TYPE_EXTENSION = 'ObjectTypeExtension';
  var INTERFACE_TYPE_EXTENSION = 'InterfaceTypeExtension';
  var UNION_TYPE_EXTENSION = 'UnionTypeExtension';
  var ENUM_TYPE_EXTENSION = 'EnumTypeExtension';
  var INPUT_OBJECT_TYPE_EXTENSION = 'InputObjectTypeExtension';
  
  // Directive Definitions
  var DIRECTIVE_DEFINITION = 'DirectiveDefinition';
}

class ASTDefs { }

#{ haxe }

eof
