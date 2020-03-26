import 'dart:core';
import 'dart:io';
import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:reflectable/reflectable.dart';
import 'dto.dart';

class HessianWriter {
  static int SIZE = 8 * 1024;

  ByteData _buffer = ByteData(SIZE);
  int _offset = 0;
  Uint8List _data;

  Map<Object, int> _refs = Map<Object, int>();

  Map<String, int> _typeRefs;

  var _classRefs = Map<String, int>();

  int _version = 1;

  HessianWriter() {}

  void reset() {
    if (_data != null) {
      _data.clear();
    }
    _refs.clear();
    _offset = 0;
  }

  void flushIfFull() {
    int offset = _offset;

    if (SIZE < offset + 1) {
      flushBuffer();
    }
  }

  void flushBuffer() {
    if (_offset > 0) {
      _data = _buffer.buffer.asUint8List(0, _offset + 1);
      _offset = 0;
    }
  }

  Uint8List call(String method, List<Object> args) {
    flushIfFull();

    int length = args != null ? args.length : 0;

    _buffer.setInt8(_offset++, 'c'.codeUnitAt(0));
    _buffer.setInt8(_offset++, _version);
    _buffer.setInt8(_offset++, 0);

    int len = method.length;
    _buffer.setInt8(_offset++, 'm'.codeUnitAt(0));
    _buffer.setInt8(_offset++, len >> 8);
    _buffer.setInt8(_offset++, len);
    printString(method, 0, len);
//    writeString(method);

    for (int i = 0; i < length; i++) {
      writeObject(args[i]);
    }

    _buffer.setInt8(_offset++, 'z'.codeUnitAt(0));

    flush();

    return this._data;
  }

  void writeBoolean(bool value) {
    if (SIZE < _offset + 16) flushBuffer();

    if (value)
      _buffer.setInt8(_offset++, 'T'.codeUnitAt(0));
    else
      _buffer.setInt8(_offset++, 'F'.codeUnitAt(0));
  }

  void writeBytes(List<int> byteBuffer, [int offset, int length]) {
    int _byteOffset = offset == null ? 0 : offset;
    int _length = length == null ? byteBuffer.length : length;
    flushIfFull();

    for (int j = _byteOffset; j < (_byteOffset + _length); j++) {
      _buffer.setInt8(this._offset++, byteBuffer[j]);
    }
  }

  void writeDouble(double value) {
    flushIfFull();
    _buffer.setInt8(_offset++, 'D'.codeUnitAt(0));
    _buffer.setFloat64(_offset, value);
    _offset += 8;
  }

  void writeInt(int value32) {
    if (SIZE <= _offset + 4) {
      flushBuffer();
    }

    _buffer.setInt8(_offset++, 'I'.codeUnitAt(0));
    _buffer.setInt32(_offset, value32);
    _offset += 4;
  }

  void writeLong(Int64 value) {
    if (SIZE <= _offset + 8) {
      flushBuffer();
    }

    _buffer.setInt8(_offset++, 'L'.codeUnitAt(0));
    _buffer.setInt64(_offset, value.toInt());
    _offset += 8;
  }

  void writeMap(Map map) {
    if (this.writeReference(map)) return;

    writeMapBegin(null);
    map.forEach((key, value) => {writeObject(key), writeObject(value)});
    writeMapEnd();
  }

  /**
   * Writes the map header to the stream.  Map writers will call
   * <code>writeMapBegin</code> followed by the map contents and then
   * call <code>writeMapEnd</code>.
   *
   * <code><pre>
   * Mt b16 b8 (<key> <value>)z
   * </pre></code>
   */
  void writeMapBegin(String type) {
    flushIfFull();

    _buffer.setInt8(_offset++, 'M'.codeUnitAt(0));
    _buffer.setInt8(_offset++, 't'.codeUnitAt(0));
    printLenString(type);
  }

  /**
   * Writes the tail of the map to the stream.
   */
  void writeMapEnd() {
    flushIfFull();
    _buffer.setInt8(_offset++, 'z'.codeUnitAt(0));
  }

  void writeNull() {
    flushIfFull();
    _buffer.setInt8(_offset++, 'N'.codeUnitAt(0));
  }

  void writeObject(Object object) {
    if (object == null) {
      writeNull();
      return;
    }

    if (object is String) {
      this.writeString(object.toString());
    } else if (object is int)
      this.writeInt(object);
    else if (object is bool)
      this.writeBoolean(object);
    else if (object is double)
      this.writeDouble(object);
    else if (object is DateTime)
      this.writeUTCDate(object.millisecondsSinceEpoch);
    else if (object is List)
      this.writeList(object);
    else if (object is Map)
      this.writeMap(object);
    else
      this.writeInstance(object);
  }

  void writeString(String value) {
    if (SIZE <= _offset + 16) {
      flushBuffer();
    }

    if (value == null) {
      _buffer.setInt8(_offset++, 'N'.codeUnitAt(0));
    } else {
      int length = value.length;
      int offset = 0;

      while (length > 0x8000) {
        int sublen = 0x8000;

        // chunk can't end in high surrogate
        int tail = value.codeUnitAt(offset + sublen - 1);

        if (0xd800 <= tail && tail <= 0xdbff) sublen--;

        _buffer.setInt8(_offset++, 's'.codeUnitAt(0));
        _buffer.setInt8(_offset++, sublen >> 8);
        _buffer.setInt8(_offset++, sublen);

        printString(value, offset, sublen);

        length -= sublen;
        offset += sublen;
      }

      _buffer.setInt8(_offset++, 'S'.codeUnitAt(0));
      _buffer.setInt8(_offset++, length >> 8);
      _buffer.setInt8(_offset++, length);

      printString(value, offset, length);
    }
  }

  /**
   * Prints a string to the stream, encoded as UTF-8
   *
   * @param v the string to print.
   */
  void printString(String v, int strOffset, int length) {
    for (int i = 0; i < length; i++) {
      if (SIZE <= _offset + 16) {
        flushBuffer();
      }

      int ch = v.codeUnitAt(i + strOffset);

      if (ch < 0x80)
        _buffer.setInt8(_offset++, ch);
      else if (ch < 0x800) {
        _buffer.setInt8(_offset++, (0xc0 + ((ch >> 6) & 0x1f)));
        _buffer.setInt8(_offset++, (0x80 + (ch & 0x3f)));
      } else {
        _buffer.setInt8(_offset++, (0xe0 + ((ch >> 12) & 0xf)));
        _buffer.setInt8(_offset++, (0x80 + ((ch >> 6) & 0x3f)));
        _buffer.setInt8(_offset++, (0x80 + (ch & 0x3f)));
      }
    }
  }

  /**
   * Prints a string to the stream, encoded as UTF-8 with preceeding length
   *
   * @param v the string to print.
   */
  void printLenString(String v) {
    if (v == null) {
      _buffer.setInt8(_offset++, 0);
      _buffer.setInt8(_offset++, 0);
    } else {
      int len = v.length;
      _buffer.setInt8(_offset++, len >> 8);
      _buffer.setInt8(_offset++, len);
      printString(v, 0, len);
    }
  }

  void writeUTCDate(int time) {
    if (SIZE < _offset + 32) flushBuffer();

    _buffer.setInt8(_offset++, 'd'.codeUnitAt(0));
    _buffer.setInt64(_offset, time);

//    buffer[offset++] = (byte) BC_DATE;
//    buffer[offset++] = ((byte) (time >> 56));
//    buffer[offset++] = ((byte) (time >> 48));
//    buffer[offset++] = ((byte) (time >> 40));
//    buffer[offset++] = ((byte) (time >> 32));
//    buffer[offset++] = ((byte) (time >> 24));
//    buffer[offset++] = ((byte) (time >> 16));
//    buffer[offset++] = ((byte) (time >> 8));
//    buffer[offset++] = ((byte) (time));

    _offset += 8;
  }

  /**
   * Writes a fault.  The fault will be written
   * as a descriptive string followed by an object:
   *
   * <code><pre>
   * F map
   * </pre></code>
   *
   * <code><pre>
   * F H
   * \x04code
   * \x10the fault code
   *
   * \x07message
   * \x11the fault message
   *
   * \x06detail
   * M\xnnjavax.ejb.FinderException
   *     ...
   * Z
   * Z
   * </pre></code>
   *
   * @param code the fault code, a three digit
   */
  void writeFault(String code, String message, Object detail) {
    flushIfFull();

    _buffer.setInt8(_offset++, 'F'.codeUnitAt(0));
    _buffer.setInt8(_offset++, 'H'.codeUnitAt(0));

    writeString("code");
    writeString(code);

    writeString("message");
    writeString(message);

    if (detail != null) {
      writeString("detail");
      writeObject(detail);
    }

    flushIfFull();
    _buffer.setInt8(_offset++, 'z'.codeUnitAt(0));
  }

  bool writeReference(Object value) {
    flushIfFull();
    int ref = _refs[value];
    if (ref == null) {
      ref = _refs.length + 1;
      _refs[value] = ref;
      return false;
    } else {
      _buffer.setInt8(_offset++, 0x51);
      writeInt(ref);
      return true;
    }
  }

  /**
   * <code><pre>
   * type ::= string
   *      ::= int
   * </code></pre>
   */
  void writeType(String type) {
    flushIfFull();

    if (type == null) {
      _buffer.setInt8(_offset++, 't'.codeUnitAt(0));
    }

    if (_typeRefs == null) _typeRefs = Map<String, int>();

    int typeRefV = _typeRefs[type];

    if (typeRefV != null) {
      writeInt(typeRefV);
    } else {
      _typeRefs[type] = _typeRefs.length;

      writeString(type);
    }
  }

  void writeList(Object obj) {
    List list = obj as List;
    bool hasEnd = writeListBegin(-1, null);

    for(var value in list){
      writeObject(value);
    }
    if (hasEnd) writeListEnd();
  }

//  void writeList(Object obj) {
//    Iterator iter = obj as Iterator;
//    bool hasEnd = writeListBegin(-1, null);
//
//    while (iter.moveNext()) {
//      Object value = iter.current();
//      writeObject(value);
//    }
//
//    if (hasEnd) writeListEnd();
//  }

  /**
   * Writes the list header to the stream.  List writers will call
   * <code>writeListBegin</code> followed by the list contents and then
   * call <code>writeListEnd</code>.
   *
   * <code><pre>
   * V
   * t b16 b8 type
   * l b32 b24 b16 b8
   * </pre></code>
   */
  bool writeListBegin(int length, String type) {
    flushIfFull();

    _buffer.setInt8(_offset++, 'V'.codeUnitAt(0));

    if (type != null) {
      _buffer.setInt8(_offset++, 't'.codeUnitAt(0));
      printLenString(type);
    }

    if (length >= 0) {
      _buffer.setInt8(_offset++, 'l'.codeUnitAt(0));
      _buffer.setInt32(_offset, length);
      _offset += 4;
    }

    return true;
  }

  /**
   * Writes the tail of the list to the stream for a variable-length list.
   */
  void writeListEnd() {
    flushIfFull();
    _buffer.setInt8(_offset++, 'z'.codeUnitAt(0));
  }


  void writeClassFieldLength(int len) {
    writeInt(len);
  }

  /**
   * Writes the tail of the object definition to the stream.
   */
  void writeObjectEnd() {}

  void writeInstance(Object obj) {
    if (this.writeReference(obj)) return;

    InstanceMirror instanceMirror = reflector.reflect(obj);

    var _fields = ReflectorUtil.getFieldList(instanceMirror.type);

    String typeName = null;
    QualifiedName qn = instanceMirror.type.metadata.firstWhere((obj) => obj is QualifiedName, orElse: () => null);
    if (qn != null) {
      typeName = qn.value;
    }
    writeMapBegin(typeName);
    _fields.forEach((field) {
      var fieldValue = instanceMirror.invokeGetter(field.simpleName);
      if (fieldValue != null) {
        writeString(field.simpleName);
        writeObject(fieldValue);
      }
    });
    writeMapEnd();
  }



  Uint8List flush() {
    flushBuffer();
    return this._data;
  }
}
