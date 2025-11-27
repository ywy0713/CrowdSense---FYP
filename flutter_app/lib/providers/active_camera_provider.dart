import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/data_service.dart';

class ActiveCameraNotifier extends StateNotifier<String?> {
  ActiveCameraNotifier() : super(null);

  void setActiveCamera(String? zoneId) {
    state = zoneId;
  }

  void clearActiveCamera() {
    state = null;
  }
}

final activeCameraProvider = StateNotifierProvider<ActiveCameraNotifier, String?>((ref) {
  return ActiveCameraNotifier();
});

