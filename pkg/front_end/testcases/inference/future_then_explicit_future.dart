// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/*@testedFeatures=inference*/
library test;

import "dart:async";

m1() {
  Future<int> f;
  var /*@type=Future<List<int>>*/ x = /*@promotedType=none*/ f
      .then<Future<List<int>>>(/*error:ARGUMENT_TYPE_NOT_ASSIGNABLE*/
          /*@returnType=List<int>*/ (/*@type=int*/ x) => /*@typeArgs=int*/ []);
  Future<List<int>> y = /*@promotedType=none*/ x;
}

m2() {
  Future<int> f;
  var /*@type=Future<List<int>>*/ x = /*@promotedType=none*/ f.then<List<int>>(
      /*@returnType=List<int>*/ (/*@type=int*/ x) => /*@typeArgs=int*/ []);
  Future<List<int>> y = /*@promotedType=none*/ x;
}
