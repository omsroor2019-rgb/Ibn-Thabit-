import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:workmanager/workmanager.dart';

import 'services/backup_service.dart';
import 'ui/app.dart';

const String weeklyBackupTask = 'binThabitWeeklyBackup';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    ui.DartPluginRegistrant.ensureInitialized();
    try {
      if (task == weeklyBackupTask) {
        await BackupService.instance.createScheduledLocalBackup();
      }
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar', null);
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      'bin-thabit-weekly-backup',
      weeklyBackupTask,
      frequency: const Duration(days: 7),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {
    // The app remains usable; manual encrypted backups are still available.
  }
  runApp(BinThabitApp(themeController: ThemeController()));
}
