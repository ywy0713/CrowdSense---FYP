import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/data_service.dart';

class ActiveCameraNotifier extends StateNotifier<Set<String>> {
  ActiveCameraNotifier() : super({});

  void setActiveCamera(String? zoneId) {
    if (zoneId != null) {
      state = {...state, zoneId};
    }
  }

  void addActiveCamera(String zoneId) {
    state = {...state, zoneId};
  }

  void removeActiveCamera(String zoneId) {
    state = state.where((id) => id != zoneId).toSet();
  }

  void clearActiveCamera() {
    state = {};
  }

  void setActiveCameras(Set<String> zoneIds) {
    state = zoneIds;
  }

  bool isActive(String zoneId) {
    return state.contains(zoneId);
  }

  String? get primaryCamera {
    return state.isNotEmpty ? state.first : null;
  }
}

final activeCameraProvider = StateNotifierProvider<ActiveCameraNotifier, Set<String>>((ref) {
  return ActiveCameraNotifier();
});

