import 'package:equatable/equatable.dart';

/// Estados posibles de la impresora
enum PrinterConnectionStatus { disconnected, connecting, connected, error }

/// Tipos de errores de impresora
enum PrinterErrorType {
  paperOut, // Sin papel
  coverOpen, // Tapa abierta
  offline, // Offline
  communicationError, // Error de comunicación
  deviceNotFound, // Dispositivo no encontrado
  unknown, // Error desconocido
}

/// Modelo inmutable del estado de la impresora
class PrinterStatus extends Equatable {
  final bool isOnline;
  final bool hasPaper;
  final bool isCoverOpen;
  final bool hasError;
  final PrinterErrorType? errorType;
  final String? errorMessage;
  final DateTime lastChecked;

  const PrinterStatus({
    required this.isOnline,
    required this.hasPaper,
    required this.isCoverOpen,
    required this.hasError,
    this.errorType,
    this.errorMessage,
    required this.lastChecked,
  });

  /// Constructor para estado desconocido
  factory PrinterStatus.unknown() {
    return PrinterStatus(
      isOnline: false,
      hasPaper: false,
      isCoverOpen: false,
      hasError: false,
      lastChecked: DateTime.now(),
    );
  }

  /// Constructor para estado saludable
  factory PrinterStatus.healthy() {
    return PrinterStatus(
      isOnline: true,
      hasPaper: true,
      isCoverOpen: false,
      hasError: false,
      lastChecked: DateTime.now(),
    );
  }

  /// Constructor para estado con error
  factory PrinterStatus.withError(PrinterErrorType errorType, String message) {
    return PrinterStatus(
      isOnline: false,
      hasPaper: errorType != PrinterErrorType.paperOut,
      isCoverOpen: errorType == PrinterErrorType.coverOpen,
      hasError: true,
      errorType: errorType,
      errorMessage: message,
      lastChecked: DateTime.now(),
    );
  }

  /// Indica si la impresora está lista para imprimir
  bool get isReadyToPrint => isOnline && hasPaper && !isCoverOpen && !hasError;

  /// Mensaje legible del estado
  String get statusMessage {
    if (hasError && errorMessage != null) return errorMessage!;
    if (!isOnline) return 'Impresora desconectada';
    if (isCoverOpen) return 'Tapa abierta';
    if (!hasPaper) return 'Sin papel';
    return 'Impresora lista';
  }

  PrinterStatus copyWith({
    bool? isOnline,
    bool? hasPaper,
    bool? isCoverOpen,
    bool? hasError,
    PrinterErrorType? errorType,
    String? errorMessage,
    DateTime? lastChecked,
  }) {
    return PrinterStatus(
      isOnline: isOnline ?? this.isOnline,
      hasPaper: hasPaper ?? this.hasPaper,
      isCoverOpen: isCoverOpen ?? this.isCoverOpen,
      hasError: hasError ?? this.hasError,
      errorType: errorType ?? this.errorType,
      errorMessage: errorMessage ?? this.errorMessage,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }

  @override
  List<Object?> get props => [
    isOnline,
    hasPaper,
    isCoverOpen,
    hasError,
    errorType,
    errorMessage,
    lastChecked,
  ];
}

/// Información de una impresora disponible
class PrinterDevice extends Equatable {
  final String devicePath;
  final String displayName;
  final bool isConnected;

  const PrinterDevice({
    required this.devicePath,
    required this.displayName,
    this.isConnected = false,
  });

  PrinterDevice copyWith({
    String? devicePath,
    String? displayName,
    bool? isConnected,
  }) {
    return PrinterDevice(
      devicePath: devicePath ?? this.devicePath,
      displayName: displayName ?? this.displayName,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  @override
  List<Object?> get props => [devicePath, displayName, isConnected];
}
