import 'package:flutter/material.dart';

import 'library_sort.dart';

@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.light,
    this.librarySort = LibrarySort.importOrder,
    this.librarySortDescending = false,
  });

  final ThemeMode themeMode;
  final LibrarySort librarySort;
  final bool librarySortDescending;

  AppSettings copyWith({
    ThemeMode? themeMode,
    LibrarySort? librarySort,
    bool? librarySortDescending,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    librarySort: librarySort ?? this.librarySort,
    librarySortDescending: librarySortDescending ?? this.librarySortDescending,
  );

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'librarySort': librarySort.name,
    'librarySortDescending': librarySortDescending,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    const keys = {'themeMode', 'librarySort', 'librarySortDescending'};
    final theme = json['themeMode'];
    final sort = json['librarySort'];
    final descending = json['librarySortDescending'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        theme is! String ||
        !ThemeMode.values.any((mode) => mode.name == theme) ||
        sort is! String ||
        !LibrarySort.values.any((order) => order.name == sort) ||
        descending is! bool) {
      throw const FormatException('Invalid application settings.');
    }
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere((mode) => mode.name == theme),
      librarySort: LibrarySort.values.firstWhere((order) => order.name == sort),
      librarySortDescending: descending,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      themeMode == other.themeMode &&
      librarySort == other.librarySort &&
      librarySortDescending == other.librarySortDescending;

  @override
  int get hashCode =>
      Object.hash(themeMode, librarySort, librarySortDescending);
}
