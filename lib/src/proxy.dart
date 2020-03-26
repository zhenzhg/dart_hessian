import 'dart:core';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'hessian_writer.dart';
import 'hessian_reader.dart';
import 'hessian_exception.dart';


typedef InvokeErrorCallback = bool Function(HessianException e);

class ProxyObject {
  static String SERVICE_URL = 'http://127.0.0.1:8080/services/';
  static InvokeErrorCallback ERROR_CALLBACK;
  static CookieJar COOKIE_JAR;
  static int CONNECT_TIMEOUT = 30 * 1000;
  static int RECEIVE_TIMEOUT = 60 * 1000 * 10;
  static Map<String,String> HEADER ={"packageName":"com.x.x"};

  Future<T> invoke<T>(String methodName, List<Object> args) async {
    String serviceName = this.runtimeType.toString();
    if(COOKIE_JAR == null) COOKIE_JAR = CookieJar();

    var url = '$SERVICE_URL$serviceName';
    try {
      HessianWriter hw = HessianWriter();

      Uint8List postData = hw.call(methodName, args);

      var dio = Dio();

      var opt = Options(
          responseType: ResponseType.bytes,
          sendTimeout: CONNECT_TIMEOUT,
          receiveTimeout: RECEIVE_TIMEOUT,
          contentType: ContentType.parse('application/octet-stream').toString(),
          headers: HEADER
      );

      //PersistCookieJar()
      Directory tempDir = await getTemporaryDirectory();
      String tempPath = tempDir.path;
      dio.interceptors.add(CookieManager(PersistCookieJar(dir: tempPath)));

      Response response = await dio.post(url, data: Stream.fromIterable(postData.map((e) => [e])), options: opt);

      if (response != null) {
        if (response.statusCode == 200) {
          Uint8List bytes = Uint8List.fromList(response.data);
          HessianReader hr = HessianReader(bytes);
          T obj = hr.readReply(null);
          return obj;
        } else {
          throw HessianException("http status code: ${response.statusCode}");
        }
      } else {
        throw HessianException("http is null");
      }
    } catch (e) {
      HessianException hessianException;
      if( e is HessianException){
        hessianException = e;
      }
      else{
        hessianException = HessianException(e.toString(),-1,e);
      }
      if(ERROR_CALLBACK != null){
        if(!ERROR_CALLBACK(hessianException)){
          rethrow;
        }
      }
      else{
        rethrow;
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    print('Got the ${invocation.memberName}\n '); //with arguments ${invocation.positionalArguments}');

    if (invocation.isMethod) {
      String s = invocation.memberName.toString();
      s = s.substring(8, s.length - 2);
      String methodName = s;

      return this.invoke(methodName, invocation.positionalArguments);
    } else {
      return super.noSuchMethod(invocation);
    }
  }
}
