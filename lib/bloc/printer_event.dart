import 'package:equatable/equatable.dart';

/// Eventos que pueden ocurrir en el sistema de impresión
abstract class PrinterEvent extends Equatable {
  const PrinterEvent();

  @override
  List<Object?> get props => [];
}

/// Solicita la lista de impresoras disponibles
class LoadPrintersEvent extends PrinterEvent {}

/// Selecciona una impresora para conectar
class SelectPrinterEvent extends PrinterEvent {
  final String devicePath;

  const SelectPrinterEvent(this.devicePath);

  @override
  List<Object?> get props => [devicePath];
}

/// Inicia la conexión con la impresora seleccionada
class ConnectPrinterEvent extends PrinterEvent {}

/// Desconecta de la impresora actual
class DisconnectPrinterEvent extends PrinterEvent {}

/// Inicia el monitoreo automático del estado
class StartMonitoringEvent extends PrinterEvent {
  final Duration interval;

  const StartMonitoringEvent({this.interval = const Duration(seconds: 3)});

  @override
  List<Object?> get props => [interval];
}

/// Detiene el monitoreo automático
class StopMonitoringEvent extends PrinterEvent {}

/// Solicita verificación manual del estado
class CheckStatusEvent extends PrinterEvent {}

/// Actualización del estado desde el monitoreo
class StatusUpdatedEvent extends PrinterEvent {
  final dynamic status; // PrinterStatus

  const StatusUpdatedEvent(this.status);

  @override
  List<Object?> get props => [status];
}

/// Limpia un error temporal
class ClearErrorEvent extends PrinterEvent {}

/// Reinicia el sistema de impresión
class ResetPrinterEvent extends PrinterEvent {}
