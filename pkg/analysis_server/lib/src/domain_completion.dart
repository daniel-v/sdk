// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library domain.completion;

import 'dart:async';

import 'package:analysis_server/protocol/protocol.dart';
import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/constants.dart';
import 'package:analysis_server/src/domain_abstract.dart';
import 'package:analysis_server/src/plugin/plugin_manager.dart';
import 'package:analysis_server/src/plugin/result_converter.dart';
import 'package:analysis_server/src/provisional/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_performance.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/generated/engine.dart' hide AnalysisResult;
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/source/source_resource.dart';
import 'package:analyzer_plugin/protocol/protocol.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_constants.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;

/**
 * Instances of the class [CompletionDomainHandler] implement a [RequestHandler]
 * that handles requests in the completion domain.
 */
class CompletionDomainHandler extends AbstractRequestHandler {
  /**
   * The maximum number of performance measurements to keep.
   */
  static const int performanceListMaxLength = 50;

  /**
   * The next completion response id.
   */
  int _nextCompletionId = 0;

  /**
   * Code completion performance for the last completion operation.
   */
  CompletionPerformance performance;

  /**
   * A list of code completion performance measurements for the latest
   * completion operation up to [performanceListMaxLength] measurements.
   */
  final List<CompletionPerformance> performanceList =
      new List<CompletionPerformance>();

  /**
   * Performance for the last priority change event.
   */
  CompletionPerformance computeCachePerformance;

  /**
   * The current request being processed or `null` if none.
   */
  CompletionRequestImpl _currentRequest;

  /**
   * Initialize a new request handler for the given [server].
   */
  CompletionDomainHandler(AnalysisServer server) : super(server);

  /**
   * Compute completion results for the given request and append them to the stream.
   * Clients should not call this method directly as it is automatically called
   * when a client listens to the stream returned by [results].
   * Subclasses should override this method, append at least one result
   * to the [controller], and close the controller stream once complete.
   */
  Future<CompletionResult> computeSuggestions(CompletionRequestImpl request,
      CompletionGetSuggestionsParams params) async {
    //
    // Allow plugins to start computing fixes.
    //
    Map<PluginInfo, Future<plugin.Response>> pluginFutures;
    plugin.CompletionGetSuggestionsParams requestParams;
    if (server.options.enableNewAnalysisDriver) {
      String file = params.file;
      int offset = params.offset;
      AnalysisDriver driver = server.getAnalysisDriver(file);
      if (driver != null) {
        requestParams = new plugin.CompletionGetSuggestionsParams(file, offset);
        pluginFutures = server.pluginManager
            .broadcastRequest(requestParams, contextRoot: driver.contextRoot);
      }
    }
    //
    // Compute completions generated by server.
    //
    Iterable<CompletionContributor> newContributors =
        server.serverPlugin.completionContributors;
    List<CompletionSuggestion> suggestions = <CompletionSuggestion>[];

    const COMPUTE_SUGGESTIONS_TAG = 'computeSuggestions';
    performance.logStartTime(COMPUTE_SUGGESTIONS_TAG);

    for (CompletionContributor contributor in newContributors) {
      String contributorTag = 'computeSuggestions - ${contributor.runtimeType}';
      performance.logStartTime(contributorTag);
      try {
        suggestions.addAll(await contributor.computeSuggestions(request));
      } on AbortCompletion {
        suggestions.clear();
        break;
      }
      performance.logElapseTime(contributorTag);
    }
    performance.logElapseTime(COMPUTE_SUGGESTIONS_TAG);

    // TODO (danrubel) if request is obsolete (processAnalysisRequest returns
    // false) then send empty results

    //
    // Add the fixes produced by plugins to the server-generated fixes.
    //
    if (pluginFutures != null) {
      List<plugin.Response> responses = await waitForResponses(pluginFutures,
          requestParameters: requestParams);
      ResultConverter converter = new ResultConverter();
      for (plugin.Response response in responses) {
        plugin.CompletionGetSuggestionsResult result =
            new plugin.CompletionGetSuggestionsResult.fromResponse(response);
        suggestions
            .addAll(result.results.map(converter.convertCompletionSuggestion));
      }
    }
    //
    // Return the result.
    //
    return new CompletionResult(
        request.replacementOffset, request.replacementLength, suggestions);
  }

  @override
  Response handleRequest(Request request) {
    if (server.searchEngine == null) {
      return new Response.noIndexGenerated(request);
    }
    return runZoned(() {
      String requestName = request.method;
      if (requestName == COMPLETION_GET_SUGGESTIONS) {
        processRequest(request);
        return Response.DELAYED_RESPONSE;
      }
      return null;
    }, onError: (exception, stackTrace) {
      server.sendServerErrorNotification(
          'Failed to handle completion domain request: ${request.toJson()}',
          exception,
          stackTrace);
    });
  }

  void ifMatchesRequestClear(CompletionRequest completionRequest) {
    if (_currentRequest == completionRequest) {
      _currentRequest = null;
    }
  }

  /**
   * Process a `completion.getSuggestions` request.
   */
  Future<Null> processRequest(Request request) async {
    performance = new CompletionPerformance();

    // extract and validate params
    CompletionGetSuggestionsParams params =
        new CompletionGetSuggestionsParams.fromRequest(request);

    AnalysisResult result;
    AnalysisContext context;
    Source source;
    if (server.options.enableNewAnalysisDriver) {
      result = await server.getAnalysisResult(params.file);

      if (result == null || !result.exists) {
        if (server.onNoAnalysisCompletion != null) {
          String completionId = (_nextCompletionId++).toString();
          await server.onNoAnalysisCompletion(
              request, this, params, performance, completionId);
          return;
        } else {
          server.sendResponse(new Response.unknownSource(request));
          return;
        }
      }

      if (params.offset < 0 || params.offset > result.content.length) {
        server.sendResponse(new Response.invalidParameter(
            request,
            'params.offset',
            'Expected offset between 0 and source length inclusive,'
            ' but found ${params.offset}'));
        return;
      }

      source = new FileSource(
          server.resourceProvider.getFile(result.path), result.uri);
    } else {
      ContextSourcePair contextSource =
          server.getContextSourcePair(params.file);

      context = contextSource.context;
      source = contextSource.source;
      if (context == null || !context.exists(source)) {
        server.sendResponse(new Response.unknownSource(request));
        return;
      }

      TimestampedData<String> contents = context.getContents(source);
      if (params.offset < 0 || params.offset > contents.data.length) {
        server.sendResponse(new Response.invalidParameter(
            request,
            'params.offset',
            'Expected offset between 0 and source length inclusive,'
            ' but found ${params.offset}'));
        return;
      }
    }

    recordRequest(performance, context, source, params.offset);

    CompletionRequestImpl completionRequest = new CompletionRequestImpl(
        result,
        context,
        server.resourceProvider,
        server.searchEngine,
        source,
        params.offset,
        performance,
        server.ideOptions);

    String completionId = (_nextCompletionId++).toString();

    setNewRequest(completionRequest);

    // initial response without results
    server.sendResponse(new CompletionGetSuggestionsResult(completionId)
        .toResponse(request.id));

    // Compute suggestions in the background
    computeSuggestions(completionRequest, params)
        .then((CompletionResult result) {
      const SEND_NOTIFICATION_TAG = 'send notification';
      performance.logStartTime(SEND_NOTIFICATION_TAG);
      sendCompletionNotification(completionId, result.replacementOffset,
          result.replacementLength, result.suggestions);
      performance.logElapseTime(SEND_NOTIFICATION_TAG);
      performance.notificationCount = 1;
      performance.logFirstNotificationComplete('notification 1 complete');
      performance.suggestionCountFirst = result.suggestions.length;
      performance.suggestionCountLast = result.suggestions.length;
      performance.complete();
    }).whenComplete(() {
      ifMatchesRequestClear(completionRequest);
    });
  }

  /**
   * If tracking code completion performance over time, then
   * record addition information about the request in the performance record.
   */
  void recordRequest(CompletionPerformance performance, AnalysisContext context,
      Source source, int offset) {
    performance.source = source;
    if (performanceListMaxLength == 0 || context == null || source == null) {
      return;
    }
    TimestampedData<String> data = context.getContents(source);
    if (data == null) {
      return;
    }
    performance.setContentsAndOffset(data.data, offset);
    while (performanceList.length >= performanceListMaxLength) {
      performanceList.removeAt(0);
    }
    performanceList.add(performance);
  }

  /**
   * Send completion notification results.
   */
  void sendCompletionNotification(String completionId, int replacementOffset,
      int replacementLength, Iterable<CompletionSuggestion> results) {
    server.sendNotification(new CompletionResultsParams(
            completionId, replacementOffset, replacementLength, results, true)
        .toNotification());
  }

  void setNewRequest(CompletionRequest completionRequest) {
    _abortCurrentRequest();
    _currentRequest = completionRequest;
  }

  /**
   * Abort the current completion request, if any.
   */
  void _abortCurrentRequest() {
    if (_currentRequest != null) {
      _currentRequest.abort();
      _currentRequest = null;
    }
  }
}

/**
 * The result of computing suggestions for code completion.
 */
class CompletionResult {
  /**
   * The length of the text to be replaced if the remainder of the identifier
   * containing the cursor is to be replaced when the suggestion is applied
   * (that is, the number of characters in the existing identifier).
   */
  final int replacementLength;

  /**
   * The offset of the start of the text to be replaced. This will be different
   * than the offset used to request the completion suggestions if there was a
   * portion of an identifier before the original offset. In particular, the
   * replacementOffset will be the offset of the beginning of said identifier.
   */
  final int replacementOffset;

  /**
   * The suggested completions.
   */
  final List<CompletionSuggestion> suggestions;

  CompletionResult(
      this.replacementOffset, this.replacementLength, this.suggestions);
}
