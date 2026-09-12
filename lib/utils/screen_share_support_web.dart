library;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Web : `getDisplayMedia` est absent sur Safari iOS (iPhone/iPad).
/// On teste la présence réelle de l'API au lieu de deviner l'agent.
bool get isScreenShareSupported {
  try {
    // Les bindings typent mediaDevices non-nullable ; le cast JSObject
    // permet l'inspection dynamique de l'API réelle du navigateur.
    final media = web.window.navigator.mediaDevices as JSObject;

    return media.has('getDisplayMedia');
  } catch (_) {
    return false;
  }
}
