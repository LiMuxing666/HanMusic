import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../data/models/app_settings.dart';
import '../data/models/library_sort.dart';

class AppSettingsService extends GetxService {
  AppSettingsService({AppSettings initial = const AppSettings()})
    : settings = initial.obs;

  final Rx<AppSettings> settings;
  bool _closed = false;

  void setThemeMode(ThemeMode value) {
    restore(settings.value.copyWith(themeMode: value));
  }

  void setLibrarySort(LibrarySort value) {
    restore(settings.value.copyWith(librarySort: value));
  }

  void setLibrarySortDescending(bool value) {
    restore(settings.value.copyWith(librarySortDescending: value));
  }

  void restore(AppSettings value) {
    if (_closed || settings.value == value) return;
    settings.value = value;
  }

  @override
  void onClose() {
    _closed = true;
    super.onClose();
  }
}
