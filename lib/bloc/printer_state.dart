import 'package:equatable/equatable.dart';
import '../models/printer_status.dart';

enum PrintStatus { idle, printing, success, error }

/// Estado del sistema de impresión
class PrinterBlocState extends Equatable {
  final List<PrinterDevice> availablePrinters;
  final PrinterDevice? selectedPrinter;
  final PrinterConnectionStatus connectionStatus;
  final PrinterStatus? printerStatus;
  final bool isMonitoring;
  final String? errorMessage;
  final bool isLoading;
  final PrintStatus printStatus;
  final String? printMessage;

  const PrinterBlocState({
    this.availablePrinters = const [],
    this.selectedPrinter,
    this.connectionStatus = PrinterConnectionStatus.disconnected,
    this.printerStatus,
    this.isMonitoring = false,
    this.errorMessage,
    this.isLoading = false,
    this.printStatus = PrintStatus.idle,
    this.printMessage,
  });

  /// Estado inicial
  factory PrinterBlocState.initial() {
    return const PrinterBlocState();
  }

  /// Indica si se puede comenzar a usar la aplicación
  bool get canStartApp {
    return connectionStatus == PrinterConnectionStatus.connected &&
        printerStatus != null &&
        printerStatus!.isReadyToPrint;
  }

  /// Indica si hay un error que debe mostrarse
  bool get hasError =>
      errorMessage != null || (printerStatus?.hasError ?? false);

  /// Mensaje de error combinado
  String? get displayErrorMessage {
    if (errorMessage != null) return errorMessage;
    if (printerStatus?.hasError ?? false) {
      return printerStatus!.errorMessage;
    }
    return null;
  }

  PrinterBlocState copyWith({
    List<PrinterDevice>? availablePrinters,
    PrinterDevice? selectedPrinter,
    PrinterConnectionStatus? connectionStatus,
    PrinterStatus? printerStatus,
    bool? isMonitoring,
    String? errorMessage,
    bool? isLoading,
    PrintStatus? printStatus,
    String? printMessage,
    bool clearError = false,
    bool clearPrintMessage = false,
  }) {
    return PrinterBlocState(
      availablePrinters: availablePrinters ?? this.availablePrinters,
      selectedPrinter: selectedPrinter ?? this.selectedPrinter,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      printerStatus: printerStatus ?? this.printerStatus,
      isMonitoring: isMonitoring ?? this.isMonitoring,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isLoading: isLoading ?? this.isLoading,
      printStatus: printStatus ?? this.printStatus,
      printMessage: clearPrintMessage
          ? null
          : (printMessage ?? this.printMessage),
    );
  }

  @override
  List<Object?> get props => [
    availablePrinters,
    selectedPrinter,
    connectionStatus,
    printerStatus,
    isMonitoring,
    errorMessage,
    isLoading,
    printStatus,
    printMessage,
  ];
}
