import 'dart:core';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:reflectable/reflectable.dart';
import 'hessian_exception.dart';
import 'dto.dart';

class HessianReader {
  int _offset = 0;

  int _length;

  Uint8List _buffer;
  ByteData _byteData;

  List<Object> _refs = List<Object>();

  StringBuffer _sbuf = StringBuffer();

  // true if this is the last chunk
  bool _isLastChunk = true;

  // the chunk length
  int _chunkLength;

  int _peek = -1;

  HessianReader(Uint8List data) {
    this._buffer = data;
    this._length = this._buffer.length;
    this._offset = 0;
    _byteData = ByteData.view(this._buffer.buffer);
  }

  int read() {
    if (_peek >= 0) {
      int value = _peek;
      _peek = -1;
      return value;
    }

    return _byteData.getUint8(_offset++);
  }

  int parseInt32() {
    if (_length <= _offset) return -1;

    int int32 = _byteData.getInt32(_offset);
    _offset += 4;
    return int32;
  }

  int parseInt64() {
    if (_length <= _offset) return -1;

    int int64 = _byteData.getInt64(_offset);
    _offset += 8;
    return int64;
  }

  double parseDouble() {
    if (_length <= _offset) return -1;

    double d = _byteData.getFloat64(_offset);
    _offset += 8;
    return d;
  }

  DateTime parseUTCDate() {
    int time = parseInt64();
    return DateTime.fromMillisecondsSinceEpoch(time);
  }

  /**
   * Reads a string
   *
   * <pre>
   * S b16 b8 string value
   * </pre>
   */
  String readString() {
    int tag = read();

    switch (String.fromCharCode(tag)) {
      case 'N':
        return null;
      case 'I':
        return parseInt32().toString();
      case 'L':
        return parseInt64().toString();
      case 'D':
        return parseDouble().toString();
      case 'S':
      case 's':
      case 'X':
      case 'x':
        _isLastChunk = tag == 'S'.codeUnitAt(0) || tag == 'X'.codeUnitAt(0);
        _chunkLength = (read() << 8) + read();

        _sbuf.clear();
        int ch;

        while ((ch = parseChar()) >= 0)
          _sbuf.writeCharCode(ch);

        return _sbuf.toString();
      default:
        throw HessianException("string $tag");
    }
  }

  /**
   * Reads a reply as an object.
   * If the reply has a fault, throws the exception.
   */
  Object readReply(ClassMirror expectedClass) {
    int tag = read();

    if (tag != 'r'.codeUnitAt(0))
      HessianException("expected hessian reply at $tag");

    int major = read();
    int minor = read();

    tag = read();
    if (tag == 'f'.codeUnitAt(0))
      throw prepareFault();
    else {
      _peek = tag;

      Object value = readObjectForClass(expectedClass);
      completeValueReply();

      return value;
    }
  }

  /**
   * Reads an arbitrary object from the input stream when the type
   * is unknown.
   */
  Object readObject() {
    int tag = read();

    switch (String.fromCharCode(tag)) {
      case 'N':
        return null;
      case 'T':
        return true;
      case 'F':
        return false;
      case 'I':
        return parseInt32();
      case 'L':
        return parseInt64();
      case 'D':
        return parseDouble();
      case 'd':
        return parseUTCDate();
      case 'x':
      case 'X':
        {
          throw HessianException("unknown code for readObject at X or x");
        }
      case 's':
      case 'S':
        {
          _isLastChunk = tag == 'S'.codeUnitAt(0);
          _chunkLength = (read() << 8) + read();

          int data;
          _sbuf.clear();

          while ((data = parseChar()) >= 0) _sbuf.writeCharCode(data);

          return _sbuf.toString();
        }
      case 'b':
      case 'B':
        {
          _isLastChunk = tag == 'B'.codeUnitAt(0);
          _chunkLength = (read() << 8) + read();

          int data;
          List<int> bos = List<int>();

          while ((data = parseByte()) >= 0) bos.add(data);

          return Int8List.fromList(bos);
        }
      case 'V':
        {
          String type = readType();
          int length = readLength();
          return readList(length, type);
        }
      case 'M':
        {
          String type = readType();
          return readMap(type);
        }
      case 'R':
        {
          int ref = parseInt32();
          return _refs[ref];
        }
      case 'r':
        {
          String type = readType();
          String url = readString();
          throw HessianException("unknown code for readObject at r");
//          return resolveRemote(type, url);
        }
      default:
        throw HessianException("unknown code for readObject at $tag");
    }
  }

  /**
   * Reads an object from the input stream with an expected type.
   */
  Object readObjectForClass(ClassMirror cl) {
//    if (cl == null || cl == reflector.reflectType(Object)) return readObject();
    if (cl == null) return readObject();

    Object value = readObject();

    return value;
  }

  Object readMap(String type) {
    var map = Map<String, dynamic>();
    int ref = addRef(map);
    while (!this.isEnd()) {
      String key = this.readObject();
      map[key] = this.readObject();
    }
    readMapEnd();

    ClassMirror cm = ReflectorUtil.parseClassMirror(type);
    if(cm != null){
      return ReflectorUtil.fromMap(cm, map);
    }

    return map;
  }



  Object readList(int length, String type) {
    var list = List<dynamic>();
    int ref = addRef(list);
    while (!this.isEnd()) {
      Object obj = this.readObject();
      list.add(obj);
    }
    readListEnd();

    return ReflectorUtil.listCast(list);
  }

  Object readObjectInstance(ClassMirror cl, List<String> def) {
    if (cl != null) {
      Object obj = cl.newInstance("", []);
      InstanceMirror instanceMirror = reflector.reflect(obj);

      def.forEach((fieldName) {
        instanceMirror.invokeSetter(fieldName, readObject());
      });

      return obj;
    } else {
      var map = Map<String, dynamic>();
      def.forEach((fieldName) {
        map[fieldName] = this.readObject();
      });

      return map;
    }
  }

  /**
   * Prepares the fault.
   */
  HessianException prepareFault() {
    Map fault = readFault();

    Object detail = fault["detail"];
    String message = fault["message"];
    int code = -1;// fault["code"];
    if(detail != null){
      var dm = detail as Map;
      if(dm.containsKey('errorCode')) code = dm['errorCode'];
    }

    return HessianException(message, code, detail);
  }

  /**
   * Completes reading the call
   *
   * <p>A successful completion will have a single value:
   *
   * <pre>
   * z
   * </pre>
   */
  void completeReply() {
    int tag = read();
    if (tag != 'z'.codeUnitAt(0)) Exception("expected end of reply at $tag");
  }

  /**
   * Completes reading the call
   *
   * <p>A successful completion will have a single value:
   *
   * <pre>
   * z
   * </pre>
   */
  void completeValueReply() {
    int tag = read();

    if (tag != 'z'.codeUnitAt(0))
      throw Exception("expected end of reply at $tag");
  }

  /**
   * Reads a header, returning null if there are no headers.
   *
   * <pre>
   * H b16 b8 value
   * </pre>
   */
  String readHeader() {
    int tag = read();

    if (tag == 'H'.codeUnitAt(0)) {
      _isLastChunk = true;
      _chunkLength = (read() << 8) + read();

      _sbuf.clear();
      int ch;
      while ((ch = parseChar()) >= 0) _sbuf.writeCharCode(ch);

      return _sbuf.toString();
    }

    _peek = tag;

    return null;
  }

  /**
   * Parses the length for an array
   *
   * <pre>
   * l b32 b24 b16 b8
   * </pre>
   */
  int readLength() {
    int code = read();

    if (code != 'l'.codeUnitAt(0)) {
      _peek = code;
      return -1;
    }

    return parseInt32();
  }

  /**
   * Parses a type from the stream.
   *
   * <pre>
   * t b16 b8
   * </pre>
   */
  String readType() {
    int code = read();

    if (code != 't'.codeUnitAt(0)) {
      _peek = code;
      return "";
    }

    _isLastChunk = true;
    _chunkLength = (read() << 8) + read();

    _sbuf.clear();
    int ch;
    while ((ch = parseChar()) >= 0) _sbuf.writeCharCode(ch);

    return _sbuf.toString();
  }

  /**
   * Reads a reference.
   */
  Object readRef() {
    return _refs[parseInt32()];
  }

  /**
   * Reads the start of a list.
   */
  int readListStart() {
    return read();
  }

  /**
   * Reads the start of a list.
   */
  int readMapStart() {
    return read();
  }

  /**
   * Returns true if this is the end of a list or a map.
   */
  bool isEnd() {
    int code = read();
    _peek = code;
    return (code < 0 || code == 'z'.codeUnitAt(0));
  }

  /**
   * Reads the end byte.
   */
  void readEnd() {
    int code = read();

    if (code == 'z'.codeUnitAt(0))
      return;
    else if (code < 0)
      throw Exception("unexpected end of file");
    else
      throw Exception("unknown code:$code");
  }

  /**
   * Reads the end byte.
   */
  void readMapEnd() {
    int code = read();

    if (code != 'z'.codeUnitAt(0))
      throw Exception("expected end of map ('z') at $code");
  }

  /**
   * Reads the end byte.
   */
  void readListEnd() {
    int code = read();
    if (code != 'z'.codeUnitAt(0))
      throw Exception("expected end of list ('z') at $code");
  }

  /**
   * Adds a list/map reference.
   */
  int addRef(Object ref) {
    if (_refs == null) _refs = List<Object>();

    _refs.add(ref);

    return _refs.length - 1;
  }

  /**
   * Adds a list/map reference.
   */
  void setRef(int i, Object ref) {
    _refs[i] = ref;
  }

  int parseChar() {
    while (_chunkLength <= 0) {
      if (_isLastChunk) return -1;

      int code = read();

      switch (String.fromCharCode(code)) {
        case 's':
        case 'x':
          _isLastChunk = false;

          _chunkLength = (read() << 8) + read();
          break;

        case 'S':
        case 'X':
          _isLastChunk = true;

          _chunkLength = (read() << 8) + read();
          break;

        default:
          throw Exception("string $code");
      }
    }
    _chunkLength--;
    return parseUTF8Char();
  }

  /**
   * Parses a single UTF8 character.
   */
  int parseUTF8Char() {
    int ch = read();

    if (ch < 0x80)
      return ch;
    else if ((ch & 0xe0) == 0xc0) {
      int ch1 = read();
      int v = ((ch & 0x1f) << 6) + (ch1 & 0x3f);

      return v;
    } else if ((ch & 0xf0) == 0xe0) {
      int ch1 = read();
      int ch2 = read();
      int v = ((ch & 0x0f) << 12) + ((ch1 & 0x3f) << 6) + (ch2 & 0x3f);

      return v;
    } else
      throw Exception("bad utf-8 encoding at $ch");
  }

  int parseByte() {
    while (_chunkLength <= 0) {
      if (_isLastChunk) {
        return -1;
      }

      int code = read();

      switch (String.fromCharCode(code)) {
        case 'b':
          _isLastChunk = false;

          _chunkLength = (read() << 8) + read();
          break;

        case 'B':
          _isLastChunk = true;

          _chunkLength = (read() << 8) + read();
          break;

        default:
          throw Exception("byte[] $code");
      }
    }

    _chunkLength--;

    return read();
  }

  /**
   * Reads a fault.
   */
  Map readFault() {
    var map = Map<String, dynamic>();

    int code = read();
    for (; code > 0 && code != 'z'.codeUnitAt(0); code = read()) {
      _peek = code;

      Object key = readObject();
      Object value = readObject();

      if (key != null && value != null) map[key] = value;
    }

    if (code != 'z'.codeUnitAt(0)) throw HessianException("fault $code");

    return map;
  }
}
