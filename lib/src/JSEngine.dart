import 'dart:async';
import 'package:jsparser/jsparser.dart';
import 'package:jsengine/jsengine.dart';
import 'package:symbol_table/symbol_table.dart';

/**
 * JS Engine written in Dart Language.
 */
class JSEngine {

  final List<Completer> awaiting = <Completer>[];

  ///Symbol table to to store global scope objects in js file
  final SymbolTable<JsObject> globalScope = new SymbolTable();
  final JsObject global = new JsObject();

  JSEngine() {
    globalScope
      ..context = global
      ..create('global', value: global);
    loadBuiltinObjects(this);
  }

  /**
   * main function which evaluates the JS code.
   * Will be called recursively throughout
   * **node** parsed JS program by JSParser
   */
  JsObject? visitProgram(Program node, [String? stackName, JSContext? ctx]) {
    CallStack callStack;
    stackName = node.filename ?? '<entry>';

    if (ctx != null) {
      callStack = ctx.callStack;
    } else {
      callStack = new CallStack();
      ctx = new JSContext(globalScope, callStack);
    }
    callStack.push(node.filename, node.line, stackName);

    // TODO: Hoist functions, declarations into global scope.
    JsObject? out;

    //JS programs are a series of statments,
    //we will loop through them and process each of them
    for (var stmt in node.body) {
      callStack.push(stmt.filename, stmt.line, stackName);
      var result = visitStatement(stmt, ctx, stackName);

      if (stmt is ExpressionStatement) {
        out = result;
      }

      callStack.pop();
    }

    callStack.pop();
    return out;
  }

  JsObject? visitStatement(
      Statement node, JSContext ctx, String stackName) {
    var scope = ctx.scope;
    var callStack = ctx.callStack;

    if (node is ExpressionStatement) {
      return visitExpression(node.expression, ctx);
    }

    if (node is ReturnStatement) {
      return visitExpression(node.argument, ctx);
    }

    if (node is BlockStatement) {
      for (var stmt in node.body) {
        callStack.push(stmt.filename, stmt.line, stackName);
        var result = visitStatement(stmt, ctx.createChild(), stackName);

        if (stmt is ReturnStatement) {
          callStack.pop();
          return result;
        }
      }

      callStack.pop();
      return null;
    }

    if (node is VariableDeclaration) {
      for (var decl in node.declarations) {
        Variable<JsObject?> symbol;
        var value = visitExpression(decl.init, ctx);

        try {
          symbol = scope.create(decl.name.value!, value: value);
        } on StateError {
          symbol = scope.assign(decl.name.value!, value);
        }

        if (value is JsFunction && value.isAnonymous && symbol != null) {
          value.properties['name'] = new JsString(symbol.name);
        }
      }

      return null;
    }

    if (node is FunctionDeclaration) {
      return visitFunctionNode(node.function, ctx);
    }

    throw callStack.error('Unsupported', node.runtimeType.toString());
  }

  JsObject? visitExpression(Expression? node, JSContext ctx) {
    var scope = ctx.scope;
    var callStack = ctx.callStack;

    if (node is NameExpression) {
      if (node.name.value == 'undefined') {
        return null;
      }

      var symbol = scope.resolve(node.name.value!);

      if (symbol != null) {
        return symbol.value;
      }

      if (global.properties.containsKey(node.name.value)) {
        return global.properties[node.name.value];
      }

      throw callStack.error('Reference', '${node.name.value} is not defined.');
    }

    if (node is MemberExpression) {
      var target = visitExpression(node.object, ctx);
      return target?.getProperty(node.property.value, this, ctx);
    }

    if (node is ThisExpression) {
      return scope.context;
    }

    if (node is ObjectExpression) {
      var props = <dynamic, JsObject?>{};

      for (var prop in node.properties) {
        props[prop.nameString] = visitExpression(prop.expression, ctx);
      }

      return new JsObject()..properties.addAll(props);
    }

    if (node is LiteralExpression) {
      if (node.isBool) {
        return new JsBoolean(node.boolValue);
      } else if (node.isString) {
        return new JsString(node.stringValue);
      } else if (node.isNumber) {
        return new JsNumber(node.numberValue);
      } else if (node.isNull) {
        return new JsNull();
      }
    }

    if (node is ConditionalExpression) {
      var condition = visitExpression(node.condition, ctx);
      return (condition?.isTruthy == true)
          ? visitExpression(node.then, ctx)
          : visitExpression(node.otherwise, ctx);
    }

    if (node is IndexExpression) {
      // TODO: What are the actual semantics of this in JavaScript?
      var target = visitExpression(node.object, ctx)!;
      var index = visitExpression(node.property, ctx)!;
      return target.properties[index.valueOf];
    }

    if (node is CallExpression) {
      var target = visitExpression(node.callee, ctx);

      if (target is JsFunction) {
        var arguments = new JsArguments(
            node.arguments.map((e) => visitExpression(e, ctx)).toList(),
            target);

        var childScope = (target.closureScope ?? scope);
        childScope = childScope.createChild(values: {'arguments': arguments});
        childScope.context = target.context ?? scope.context;

        JsObject? result;

        if (target.declaration != null) {
          callStack.push(target.declaration!.filename, target.declaration!.line,
              target.name);
        }

        if (node.isNew && target is! JsConstructor) {
          result = target.newInstance();
          childScope.context = result;
          target.f(this, arguments, new JSContext(childScope, callStack));
        } else {
          result = target.f(
              this, arguments, new JSContext(childScope, callStack));
        }

        if (target.declaration != null) {
          callStack.pop();
        }

        return result;
      } else {
        if (node.isNew) {
          throw callStack.error(
              'Type',
              '${target?.valueOf ??
                  'undefined'} is not a constructor.');
        } else {
          throw callStack.error(
              'Type',
              '${target?.valueOf ??
                  'undefined'} is not a function.');
        }
      }
    }

    if (node is FunctionExpression) {
      return visitFunctionNode(node.function, ctx);
    }

    if (node is ArrayExpression) {
      var items = node.expressions.map((e) => visitExpression(e, ctx));
      return new JsArray()..valueOf.addAll(items);
    }

    if (node is BinaryExpression) {
      var left = visitExpression(node.left, ctx);
      var right = visitExpression(node.right, ctx);
      return performBinaryOperation(node.operator, left, right, ctx);
    }

    if (node is AssignmentExpression) {
      var l = node.left;

      if (l is NameExpression) {
        if (node.operator == '=') {
          return scope
              .assign(l.name.value!, visitExpression(node.right, ctx))
              .value;
        } else {
          var trimmedOp = node.operator!.substring(0, node.operator!.length - 1);
          return scope
              .assign(
                l.name.value!,
                performNumericalBinaryOperation(
                  trimmedOp,
                  visitExpression(l, ctx),
                  visitExpression(node.right, ctx),
                  ctx,
                ),
              )
              .value;
        }
      } else if (l is MemberExpression) {
        var left = visitExpression(l.object, ctx);

        if (node.operator == '=') {
          return left!.setProperty(
              l.property.value, visitExpression(node.right, ctx));
        } else {
          var trimmedOp = node.operator!.substring(0, node.operator!.length - 1);
          return left!.setProperty(
            l.property.value,
            performNumericalBinaryOperation(
              trimmedOp,
              left.getProperty(l.property.value, this, ctx),
              visitExpression(node.right, ctx),
              ctx,
            ),
          );
        }
      } else if (l is IndexExpression) {
        // TODO: Set values, extend arrays
      } else {
        throw callStack.error(
            'Reference', 'Invalid left-hand side in assignment');
      }
    }

    if (node is SequenceExpression) {
      return node.expressions.map((e) => visitExpression(e, ctx)).last;
    }

    if (node is UnaryExpression) {
      if (node.operator == 'delete') {
        var left = node.argument;

        if (left is IndexExpression) {
          var l = visitExpression(left.object, ctx);
          var property = visitExpression(left.property, ctx);
          var idx = coerceToNumber(property, this, ctx);

          if (l is JsArray && idx.isFinite) {
            if (idx >= 0 && idx < l.valueOf.length) {
              l.valueOf[idx.toInt()] = new JsEmptyItem();
            }
          } else if (l is! JsBuiltinObject) {
            return new JsBoolean(l!.removeProperty(property, this, ctx));
          }
        } else if (left is MemberExpression) {
          var l = visitExpression(left.object, ctx);

          if (l is! JsBuiltinObject) {
            return new JsBoolean(
                l!.removeProperty(left.property.value, this, ctx));
          }
        }

        return new JsBoolean(true);
      }

      var expr = visitExpression(node.argument, ctx);

      // +, -, !, ~, typeof, void, delete
      switch (node.operator) {
        case '!':
          return new JsBoolean(expr?.isTruthy != true);
        case '+':
          return new JsNumber(coerceToNumber(expr, this, ctx));
        case '~':
          var n = coerceToNumber(expr, this, ctx);
          if (!n.isFinite) return new JsNumber(n);
          return new JsNumber(-(n + 1));
        case '-':
          var value = coerceToNumber(expr, this, ctx);

          if (value == null || value.isNaN) {
            return new JsNumber(double.nan);
          } else if (!value.isFinite) {
            return new JsNumber(
                value.isNegative ? double.infinity : double.negativeInfinity);
          } else {
            return new JsNumber(-1.0 * value);
          }

          break;
        case 'typeof':
          return new JsString(expr?.typeof ?? 'undefined');
        case 'void':
          return null;
        default:
          throw callStack.error('Unsupported', node.operator);
      }
    }

    throw callStack.error('Unsupported', node.runtimeType.toString());
  }

  JsObject? performBinaryOperation(
      String? op, JsObject? left, JsObject? right, JSContext ctx) {
    // TODO: May be: ==, !=, ===, !==, in, instanceof
    if (op == '==') {
      // TODO: Loose equality
      throw new UnimplementedError('== operator');
    } else if (op == '===') {
      // TODO: Override operator
      return new JsBoolean(left == right);
    } else if (op == '&&') {
      return (left?.isTruthy != true) ? left : right;
    } else if (op == '||') {
      return (left?.isTruthy == true) ? left : right;
    } else if (op == '<') {
      return safeBooleanOperation(left, right, this, ctx, (l, r) => l < r);
    } else if (op == '<=') {
      return safeBooleanOperation(left, right, this, ctx, (l, r) => l <= r);
    } else if (op == '>') {
      return safeBooleanOperation(left, right, this, ctx, (l, r) => l > r);
    } else if (op == '>=') {
      return safeBooleanOperation(left, right, this, ctx, (l, r) => l >= r);
    } else {
      return performNumericalBinaryOperation(op, left, right, ctx);
    }
  }

  JsObject performNumericalBinaryOperation(
      String? op, JsObject? left, JsObject? right, JSContext ctx) {
    if (op == '+' && (!canCoerceToNumber(left) || !canCoerceToNumber(right))) {
      return new JsString(left.toString() + right.toString());
    } else {
      var l = coerceToNumber(left, this, ctx);
      var r = coerceToNumber(right, this, ctx);

      if (l.isNaN || r.isNaN) {
        return new JsNumber(double.nan);
      }

      // =, +=, -=, *=, /=, %=, <<=, >>=, >>>=, |=, ^=, &=
      switch (op) {
        case '+':
          return new JsNumber(l + r);
        case '-':
          return new JsNumber(l - r);
        case '*':
          return new JsNumber(l * r);
        case '/':
          return new JsNumber(l / r);
        case '%':
          return new JsNumber(l % r);
        case '<<':
          return new JsNumber(l.toInt() << r.toInt());
        case '>>':
          return new JsNumber(l.toInt() >> r.toInt());
        case '>>>':
          // TODO: Is a zero-filled right shift relevant with Dart?
          return new JsNumber(l.toInt() >> r.toInt());
        case '|':
          return new JsNumber(l.toInt() | r.toInt());
        case '^':
          return new JsNumber(l.toInt() ^ r.toInt());
        case '&':
          return new JsNumber(l.toInt() & r.toInt());
        default:
          throw new ArgumentError();
      }
    }
  }

  JsObject visitFunctionNode(FunctionNode node, JSContext ctx) {
    late JsFunction function;
    function = new JsFunction(ctx.scope.context, (samurai, arguments, ctx) {
      for (double i = 0.0; i < node.params.length; i++) {
        ctx.scope.create(node.params[i.toInt()].value!,
            value: arguments.properties[i]);
      }

      return visitStatement(node.body, ctx, function.name);
    });
    function.declaration = node;
    function.properties['length'] = new JsNumber(node.params.length);
    function.properties['name'] = new JsString(node.name?.value ?? 'anonymous');

    // TODO: What about hoisting???
    if (node.name != null) {
      ctx.scope.create(node.name!.value!, value: function, constant: true);
    }

    function.closureScope = ctx.scope.fork();
    function.closureScope!.context = ctx.scope.context;
    return function;
  }

  JsObject? invoke(JsFunction target, List<JsObject?> args, JSContext ctx) {
    var scope = ctx.scope, callStack = ctx.callStack as SymbolTable<JsObject?>;
    var childScope = (target.closureScope ?? scope);
    var arguments = new JsArguments(args, target);
    childScope = childScope.createChild(values: {'arguments': arguments});
    childScope.context = target.context ?? scope.context;
    print('${target.context} => ${childScope.context}');

    JsObject? result;

    if (target.declaration != null) {
      callStack.push(
          target.declaration!.filename, target.declaration!.line, target.name);
    }

    result =
        target.f(this, arguments, new JSContext(childScope, callStack as CallStack));

    if (target.declaration != null) {
      callStack.pop();
    }

    return result;
  }
}
