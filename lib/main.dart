import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'bloc/printer_bloc.dart';
import 'bloc/printer_event.dart';
import 'screens/printer_monitor_screen.dart';
import 'services/printer_service.dart';

void main() {
  runApp(const PrinterMonitorApp());
}

class PrinterMonitorApp extends StatelessWidget {
  const PrinterMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Monitor de Impresora',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
        ),
      ),
      home: BlocProvider(
        create: (context) =>
            PrinterBloc(printerService: PrinterService())
              ..add(LoadPrintersEvent()),
        child: const PrinterMonitorScreen(),
      ),
    );
  }
}
