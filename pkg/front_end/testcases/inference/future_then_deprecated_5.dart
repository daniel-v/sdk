// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*@testedFeatures=inference*/
library test;

import 'dart:async';

class MyFuture<T> implements Future<T> {
  MyFuture() {}
  MyFuture.value(T x) {}
  dynamic noSuchMethod(invocation);
  MyFuture<S> then<S>(dynamic f(T x), {Function onError}) => null;
}

void main() {
  Future f;
  Future<int> t1 = /*@promotedType=none*/ f.then(
      /*@returnType=Future<int>*/ (/*@type=dynamic*/ _) async =>
          await new MyFuture<int>.value(3));
  Future<int> t2 = /*@promotedType=none*/ f
      .then(/*@returnType=Future<int>*/ (/*@type=dynamic*/ _) async {
    return await new MyFuture<int>.value(3);
  });
  Future<int> t3 = /*@promotedType=none*/ f
      .then(/*@returnType=Future<int>*/ (/*@type=dynamic*/ _) async => 3);
  Future<int> t4 = /*@promotedType=none*/ f
      .then(/*@returnType=Future<int>*/ (/*@type=dynamic*/ _) async {
    return 3;
  });
  Future<int> t5 = /*@promotedType=none*/ f.then(
      /*@returnType=MyFuture<int>*/ (/*@type=dynamic*/ _) =>
          new MyFuture<int>.value(3));
  Future<int> t6 = /*@promotedType=none*/ f
      .then(/*@returnType=MyFuture<int>*/ (/*@type=dynamic*/ _) {
    return new MyFuture<int>.value(3);
  });
  Future<int> t7 = /*@promotedType=none*/ f.then(
      /*@returnType=Future<int>*/ (/*@type=dynamic*/ _) async =>
          new MyFuture<int>.value(3));
  Future<int> t8 = /*@promotedType=none*/ f
      .then(/*@returnType=Future<int>*/ (/*@type=dynamic*/ _) async {
    return new MyFuture<int>.value(3);
  });
}
