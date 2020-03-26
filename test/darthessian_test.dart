import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_hessian/dart_hessian.dart';

void main() {

  group("hessian", () {
    test(".中文字符序列化反序列化", () async {
      var str = "序列化测试字符串🌈";
      HessianWriter hessianWriter = HessianWriter();
      hessianWriter.writeString(str);
      Uint8List data = hessianWriter.flush();

      HessianReader hessianReader = HessianReader(data);
      var ret = hessianReader.readString();
      expect(ret, equals(str));
    });
  });
}
