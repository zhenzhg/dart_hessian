import 'dart:convert';
import 'dart:core';

import 'package:reflectable/reflectable.dart';

// Annotate with this class to enable reflection.
class Reflector extends Reflectable {
  const Reflector() : super(invokingCapability, typingCapability, reflectedTypeCapability); // Request the capability to invoke methods.
}

const reflector = const Reflector();

class QualifiedName {
  final String value;

  const QualifiedName(this.value);
}

class ReflectorUtil {
  static Map<ClassMirror, List<VariableMirror>> _cacheFieldMap = Map();
  static Map<String, ClassMirror> _classMapping = Map();

  static List<VariableMirror> getFieldList(ClassMirror clm) {
    if (_cacheFieldMap.containsKey(clm)) return _cacheFieldMap[clm];

    var declarations = clm.declarations;
    var _fields = List<VariableMirror>();

    declarations.forEach((key, value) {
      if (value is VariableMirror) {
        _fields.add(value);
      }
    });

    _cacheFieldMap[clm] = _fields;
    return _fields;
  }

  static Map<String, dynamic> toMap(dynamic obj) {
    var map = Map<String, dynamic>();
    var im = reflector.reflect(obj);
    var fields = ReflectorUtil.getFieldList(im.type);
    fields.forEach((f) {
      var fv = im.invokeGetter(f.simpleName);
      if (fv != null && fv is Dto) {
        fv = toMap(fv);
      }
      map[f.simpleName] = fv;
    });

    return map;
  }

  static Object fromMap(ClassMirror cm, Map<String, dynamic> map) {
    List<VariableMirror> _fields = ReflectorUtil.getFieldList(cm);

    Object value = cm.newInstance("", []);
    InstanceMirror im = reflector.reflect(value);

    _fields.forEach((field) {
      if (map.containsKey(field.simpleName)) {
        var fv = map[field.simpleName];
//        print('${field.simpleName}:${field.reflectedType}');
        if (fv != null) {
          if (fv is Map && field.reflectedType != Map) fv = fromMap(reflector.reflectType(field.reflectedType), fv);
          if (fv is String && field.reflectedType == DateTime) fv = DateTime.parse(fv);
        }
        if (fv is Iterable && fv.length > 0) {
          fv = listCast(fv);
        }
        im.invokeSetter(field.simpleName, fv);
      }
    });
    return value;
  }

  static ClassMirror parseClassMirror(String className) {
    if (null == className) {
      return null;
    }
    if (_classMapping.length == 0) {
      //init map
      initClassMapping();
    }
    if (_classMapping.containsKey(className)) return _classMapping[className];
    return null;
  }

  static void initClassMapping() {
    for (var cm in reflector.annotatedClasses) {
      QualifiedName qn = cm.metadata.firstWhere((obj) => obj is QualifiedName, orElse: () => null);
      if (qn != null) {
        _classMapping[qn.value] = cm;
      }
    }
  }

  static Iterable listCast(Iterable<dynamic> list) {
    if (list == null || list.length == 0) {
      return null;
    }

    //找到一个不为null的元素
    var one = list.firstWhere((obj) => obj != null, orElse: () => null);
    //如果没有找到不为null的元素，说明集合所有元素都是null，所以返回null
    if (one == null) return null;

    if (one is String) return list.cast<String>();
    if (one is int) return list.cast<int>();
    if (one is double) return list.cast<double>();
    if (one is DateTime) return list.cast<DateTime>();
    if (one is Iterable) return listCast(one);
    if (one is Null) return list.cast<Null>();
    if (one is ListCast) return one.listCast(list);

    return list.cast<Object>();
  }
}

class ListCast<E>{
  Iterable<E> listCast(Iterable<dynamic> iterable) {
    return iterable.cast<E>();
  }
}

@reflector
class Dto {

  @override
  String toString() {
    return toJson();
  }

  String toJson() {
    var map = ReflectorUtil.toMap(this);
    return jsonEncode(map, toEncodable: (item) {
      if (item is DateTime) {
        return item.toIso8601String();
      }
      return item;
    });
  }

  static T fromJson<T extends Dto>(String jsonStr) {
    var map = jsonDecode(jsonStr);

    return ReflectorUtil.fromMap(reflector.reflectType(T), map);
  }
}
