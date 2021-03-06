// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library test.kernel.closures.suite;

import 'dart:async' show Future;

import 'dart:io' show File;

import 'package:analyzer/src/generated/sdk.dart' show DartSdk;

import 'package:analyzer/src/kernel/loader.dart' show DartLoader;

import 'package:testing/testing.dart'
    show Chain, Result, Step, TestDescription, runMe;

import 'package:kernel/ast.dart' show Program, Library;

import 'package:kernel/target/targets.dart' show Target, TargetFlags, getTarget;

import 'package:front_end/src/fasta/testing/kernel_chain.dart';

import 'package:front_end/src/fasta/ticker.dart' show Ticker;

import 'package:front_end/src/fasta/dill/dill_target.dart' show DillTarget;

import 'package:front_end/src/fasta/kernel/kernel_target.dart'
    show KernelTarget;

import 'package:front_end/src/fasta/translate_uri.dart' show TranslateUri;

import 'package:front_end/src/fasta/errors.dart' show InputError;

import 'package:kernel/interpreter/interpreter.dart';

class InterpreterContext extends TestContext {
  final TranslateUri uriTranslator;

  final List<Step> steps;

  Future<Program> platform;

  InterpreterContext(Uri sdk, Uri vm, Uri packages, bool strongMode,
      DartSdk dartSdk, this.uriTranslator)
      : steps = <Step>[
          const FastaCompile(),
          const Interpret(),
          const MatchLogExpectation(".expect"),
        ],
        super(sdk, vm, packages, strongMode, dartSdk);

  Future<Program> createPlatform() {
    return new Future<Program>(() async {
      DartLoader loader = await createLoader();
      Target target =
          getTarget("vm", new TargetFlags(strongMode: options.strongMode));
      loader.loadProgram(Uri.base.resolve("pkg/fasta/test/platform.dart"),
          target: target);
      var program = loader.program;
      if (loader.errors.isNotEmpty) {
        throw loader.errors.join("\n");
      }
      Library mainLibrary = program.mainMethod.enclosingLibrary;
      program.uriToSource.remove(mainLibrary.fileUri);
      program = new Program(
          program.libraries.where((Library l) => l != mainLibrary).toList(),
          program.uriToSource);
      target.performModularTransformations(program);
      target.performGlobalTransformations(program);
      return program;
    });
  }

  static Future<InterpreterContext> create(
      Chain suite, Map<String, String> environment) async {
    return TestContext.create(suite, environment, (Chain suite,
        Map<String, String> environment,
        Uri sdk,
        Uri vm,
        Uri packages,
        bool strongMode,
        DartSdk dartSdk,
        bool updateExpectations) async {
      TranslateUri uriTranslator = await TranslateUri.parse(packages);
      return new InterpreterContext(
          sdk, vm, packages, strongMode, dartSdk, uriTranslator);
    });
  }
}

class FastaCompile extends Step<TestDescription, Program, InterpreterContext> {
  const FastaCompile();

  String get name => "fasta compile";

  Future<Result<Program>> run(
      TestDescription description, InterpreterContext context) async {
    Program platform = await context.createPlatform();
    Ticker ticker = new Ticker();
    DillTarget dillTarget = new DillTarget(ticker, context.uriTranslator);
    dillTarget.loader
      ..input = Uri.parse("org.dartlang:platform")
      ..setProgram(platform);
    KernelTarget sourceTarget =
        new KernelTarget(dillTarget, context.uriTranslator, false);

    Program p;
    try {
      sourceTarget.read(description.uri);
      await dillTarget.writeOutline(null);
      await sourceTarget.writeOutline(null);
      p = await sourceTarget.writeProgram(null);
    } on InputError catch (e, s) {
      return fail(null, e.error, s);
    }

    return pass(p);
  }
}

class Interpret extends Step<Program, EvaluationLog, InterpreterContext> {
  const Interpret();

  String get name => "interpret";

  Future<Result<EvaluationLog>> run(Program program, _) async {
    Library library = program.libraries
        .firstWhere((Library library) => library.importUri.scheme != "dart");
    Uri uri = library.importUri;

    StringBuffer buffer = new StringBuffer();
    log.onRecord.listen((LogRecord rec) => buffer.write(rec.message));
    try {
      new Interpreter(program).run();
    } catch (e, s) {
      return crash(e, s);
    }

    return pass(new EvaluationLog(uri, "$buffer"));
  }
}

class MatchLogExpectation extends Step<EvaluationLog, int, InterpreterContext> {
  final String suffix;

  String get name => "match log expectation";

  const MatchLogExpectation(this.suffix);

  Future<Result<int>> run(EvaluationLog result, _) async {
    Uri uri = result.uri;

    File expectedFile = new File("${uri.toFilePath()}$suffix");
    if (await expectedFile.exists()) {
      String expected = await expectedFile.readAsString();
      if (expected.trim() != result.log.trim()) {
        String diff = await runDiff(expectedFile.uri, result.log);
        return fail(null, "$uri doesn't match ${expectedFile.uri}\n$diff");
      } else {
        return pass(0);
      }
    }
    return fail(
        null,
        """Please create file ${expectedFile.path} with this content:
        ${result.log}""");
  }
}

class EvaluationLog {
  /// Evaluated program uri.
  final Uri uri;

  /// Evaluated program log.
  final String log;

  EvaluationLog(this.uri, this.log);
}

main(List<String> arguments) =>
    runMe(arguments, InterpreterContext.create, "testing.json");
