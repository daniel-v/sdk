// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Code generation for the file "AnalysisServer.java".
 */
library java.generator.types;

import 'api.dart';
import 'codegen_java.dart';
import 'codegen_tools.dart';
import 'from_html.dart';

/**
 * Type references in the spec that are named something else in Java.
 */
const Map<String, String> _typeRenames = const {
  'Override': 'OverrideMember',
};

/**
 * A map between the field names and values for the Element object such as:
 * 
 * private static final int ABSTRACT = 0x01;
 */
const Map<String, String> _extraFieldsOnElement = const {
  'ABSTRACT': '0x01',
  'CONST': '0x02',
  'FINAL': '0x04',
  'TOP_LEVEL_STATIC': '0x08',
  'PRIVATE': '0x10',
  'DEPRECATED': '0x20',
};

/**
 * A map between the method names and field names to generate additional methods on the Element object:
 * 
 * public boolean isFinal() {
 *   return (flags & FINAL) != 0;
 * }
 */
const Map<String, String> _extraMethodsOnElement = const {
  'isAbstract': 'ABSTRACT',
  'isConst': 'CONST',
  'isDeprecated': 'DEPRECATED',
  'isFinal': 'FINAL',
  'isPrivate': 'PRIVATE',
  'isTopLevelOrStatic': 'TOP_LEVEL_STATIC',
};

class CodegenJavaType extends CodegenJavaVisitor {

  String className;
  TypeDefinition typeDef;

  CodegenJavaType(Api api, String className)
      : super(api),
        this.className = className;

  @override
  void visitTypeDefinition(TypeDefinition typeDef) {
    outputHeader(javaStyle: true);
    writeln('package com.google.dart.server.generated.types;');
    writeln();
    if (typeDef.type is TypeObject) {
      _writeTypeObject(typeDef);
    } else if (typeDef.type is TypeEnum) {
      _writeTypeEnum(typeDef);
    }
  }

  void _writeTypeObject(TypeDefinition typeDef) {
    writeln('import java.util.Arrays;');
    writeln('import java.util.List;');
    writeln('import java.util.Map;');
    writeln('import com.google.dart.server.utilities.general.ObjectUtilities;');
    writeln('import org.apache.commons.lang3.StringUtils;');
    writeln();
    javadocComment(toHtmlVisitor.collectHtml(() {
      toHtmlVisitor.translateHtml(typeDef.html);
      toHtmlVisitor.br();
      toHtmlVisitor.write('@coverage dart.server.generated.types');
    }));
    writeln('@SuppressWarnings("unused")');
    makeClass('public class ${className}', () {
      //
      // fields
      //
      //
      // public static final "EMPTY_ARRAY" field
      // i.e. "public static final Parameter[] EMPTY_ARRAY = new Parameter[0];"
      //
      publicField(javaName("EMPTY_ARRAY"), () {
        javadocComment(toHtmlVisitor.collectHtml(() {
          toHtmlVisitor.write('An empty array of {@link ${className}}s.');
        }));
        writeln(
            'public static final ${className}[] EMPTY_ARRAY = new ${className}[0];');
      });

      //
      // Extra filds on the Element type such as:
      // private static final int ABSTRACT = 0x01;
      //
      if (className == 'Element') {
        _extraFieldsOnElement.forEach((String name, String value) {
          publicField(javaName(name), () {
            writeln('private static final int ${name} = ${value};');
          });
        });
      }

      //
      // "private static String name;" fields:
      //
      TypeObject typeObject = typeDef.type as TypeObject;
      List<TypeObjectField> fields = typeObject.fields;
      // TODO (jwren) we need to possibly remove fields such as "type" in
      // these objects: AddContentOverlay | ChangeContentOverlay | RemoveContentOverlay
      for (TypeObjectField field in fields) {
        privateField(javaName(field.name), () {
          javadocComment(toHtmlVisitor.collectHtml(() {
            toHtmlVisitor.translateHtml(field.html);
          }));
          writeln(
              'private final ${javaType(field.type)} ${javaName(field.name)};');
        });
      }

      //
      // constructor
      //
      constructor(className, () {
        javadocComment(toHtmlVisitor.collectHtml(() {
          toHtmlVisitor.write('Constructor for {@link ${className}}.');
        }));
        write('public ${className}(');
        // write out parameters to constructor
        List<String> parameters = new List();
        for (TypeObjectField field in fields) {
          parameters.add('${javaType(field.type)} ${javaName(field.name)}');
        }
        write(parameters.join(', '));
        writeln(') {');
        // write out the assignments in the body of the constructor
        for (TypeObjectField field in fields) {
          writeln('  this.${javaName(field.name)} = ${javaName(field.name)};');
        }
        writeln('}');
      });

      //
      // getter methods
      //
      for (TypeObjectField field in fields) {
        publicMethod('get${javaName(field.name)}', () {
          javadocComment(toHtmlVisitor.collectHtml(() {
            toHtmlVisitor.translateHtml(field.html);
          }));
          writeln(
              'public ${javaType(field.type)} get${capitalize(javaName(field.name))}() {');
          writeln('  return ${javaName(field.name)};');
          writeln('}');
        });
      }

      //
      // equals method
      //
      publicMethod('equals', () {
        writeln('@Override');
        writeln('public boolean equals(Object obj) {');
        indent(() {
          writeln('if (obj instanceof ${className}) {');
          indent(() {
            writeln('${className} other = (${className}) obj;');
            writeln('return');
            indent(() {
              List<String> equalsForField = new List<String>();
              for (TypeObjectField field in fields) {
                equalsForField.add(_equalsLogicForField(field, 'other'));
              }
              write(equalsForField.join(' && \n'));
            });
            writeln(';');
          });
          writeln('}');
          writeln('return false;');
        });
        writeln('}');
      });

      //
      // hashCode
      //
      // TODO (jwren) have hashCode written out
      //
      // toString
      //
      publicMethod('toString', () {
        writeln('@Override');
        writeln('public String toString() {');
        indent(() {
          writeln('StringBuilder builder = new StringBuilder();');
          writeln('builder.append(\"[\");');
          for (int i = 0; i < fields.length; i++) {
            writeln("builder.append(\"${javaName(fields[i].name)}=\");");
            write("builder.append(${_toStringForField(fields[i])}");
            if (i + 1 != fields.length) {
              // this is not the last field
              write(' + \", \"');
            }
            writeln(');');
          }
          writeln('builder.append(\"]\");');
          writeln('return builder.toString();');
        });
        writeln('}');
      });

      //
      // Extra methods for the Element type such as:
      // public boolean isFinal() {
      //   return (flags & FINAL) != 0;
      // }
      //
      if (className == 'Element') {
        _extraMethodsOnElement.forEach((String methodName, String fieldName) {
          publicMethod(methodName, () {
            writeln(
                'public boolean ${methodName}() {');
            writeln('  return (flags & ${fieldName}) != 0;');
            writeln('}');
          });
        });
      }

    });
  }

  void _writeTypeEnum(TypeDefinition typeDef) {
    javadocComment(toHtmlVisitor.collectHtml(() {
      toHtmlVisitor.translateHtml(typeDef.html);
      toHtmlVisitor.br();
      toHtmlVisitor.write('@coverage dart.server.generated.types');
    }));
    makeClass('public class ${className}', () {
      TypeEnum typeEnum = typeDef.type as TypeEnum;
      List<TypeEnumValue> values = typeEnum.values;
      //
      // enum fields
      //
      for (TypeEnumValue value in values) {
        privateField(javaName(value.value), () {
          javadocComment(toHtmlVisitor.collectHtml(() {
            toHtmlVisitor.translateHtml(value.html);
          }));
          writeln(
              'public static final String ${value.value} = \"${value.value}\";');
        });
      }
    });
  }

  String _equalsLogicForField(TypeObjectField field, String other) {
    String name = javaName(field.name);
    if (isPrimitive(field.type)) {
      return '${other}.${name} == ${name}';
    } else if (isArray(field.type)) {
      return 'Arrays.equals(other.${name}, ${name})';
    } else {
      return 'ObjectUtilities.equals(${other}.${name}, ${name})';
    }
  }

  String _toStringForField(TypeObjectField field) {
    String name = javaName(field.name);
    if (isArray(field.type) || isList(field.type)) {
      return 'StringUtils.join(${name}, ", ")';
    } else {
      return name;
    }
  }

  /**
   * Get the name of the consumer class for responses to this request.
   */
  String consumerName(Request request) {
    return camelJoin([request.method, 'consumer'], doCapitalize: true);
  }
}

final String pathToGenTypes =
    '../../../../editor/tools/plugins/com.google.dart.server/src/com/google/dart/server/generated/types/';

final GeneratedDirectory targetDir = new GeneratedDirectory(pathToGenTypes, () {
  Api api = readApi();
  Map<String, FileContentsComputer> map =
      new Map<String, FileContentsComputer>();
  for (String typeNameInSpec in api.types.keys) {
    TypeDefinition typeDef = api.types[typeNameInSpec];
    if (typeDef.type is TypeObject || typeDef.type is TypeEnum) {
      // This is for situations such as 'Override' where the name in the spec
      // doesn't match the java object that we generate:
      String typeNameInJava = typeNameInSpec;
      if (_typeRenames.containsKey(typeNameInSpec)) {
        typeNameInJava = _typeRenames[typeNameInSpec];
      }
      map['${typeNameInJava}.java'] = () {
        // create the visitor
        CodegenJavaType visitor = new CodegenJavaType(api, typeNameInJava);
        return visitor.collectCode(() {
          visitor.visitTypeDefinition(typeDef);
        });
      };
    }
  }
  return map;
});

/**
 * Translate spec_input.html into AnalysisServer.java.
 */
main() {
  targetDir.generate();
}
