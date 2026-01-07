import 'package:equatable/equatable.dart';

/// Eventos que pueden ocurrir en el sistema de impresión
abstract class PrinterEvent extends Equatable {
  const PrinterEvent();

  @override
  List<Object?> get props => [];
}

/// Solicita la lista de impresoras disponibles
class LoadPrintersEvent extends PrinterEvent {}

/// Selecciona una impresora
class SelectPrinterEvent extends PrinterEvent {
  final String devicePath;

  const SelectPrinterEvent(this.devicePath);

  @override
  List<Object?> get props => [devicePath];
}

/// Conecta con la impresora seleccionada
class ConnectPrinterEvent extends PrinterEvent {}

/// Desconecta la impresora
class DisconnectPrinterEvent extends PrinterEvent {}

/// Inicia el monitoreo automático
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

/// Evento interno: tick para reintentos de reconexión automática
class AutoReconnectTickEvent extends PrinterEvent {
  const AutoReconnectTickEvent();
}

/// Actualización del estado desde el monitoreo
class StatusUpdatedEvent extends PrinterEvent {
  final dynamic status;

  const StatusUpdatedEvent(this.status);

  @override
  List<Object?> get props => [status];
}

/// Limpia errores
class ClearErrorEvent extends PrinterEvent {}

/// Reinicia el estado de la impresora
class ResetPrinterEvent extends PrinterEvent {}
