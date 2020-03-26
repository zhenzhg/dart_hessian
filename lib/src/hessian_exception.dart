class HessianException implements Exception {
  int code = -1;
  Object detail;
  String message;

  HessianException(this.message, [this.code, this.detail]);

  @override
  String toString() =>
      "HessianException [code:$code]: " +
          (message ?? "") +
          (detail ?? "").toString();
}
