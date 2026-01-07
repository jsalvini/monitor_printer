import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:rxdart/rxdart.dart';
import '../models/printer_status.dart';
import '../services/printer_service.dart';
import 'printer_event.dart';
import 'printer_state.dart';

/// BLoC que gestiona el estado y lógica de la impresora
class PrinterBloc extends Bloc<PrinterEvent, PrinterBlocState> {
  final PrinterService _printerService;
  Timer? _monitoringTimer;

  PrinterBloc({PrinterService? printerService})
    : _printerService = printerService ?? PrinterService(),
      super(PrinterBlocState.initial()) {
    // Registrar handlers de eventos
    on<LoadPrintersEvent>(_onLoadPrinters);
    on<SelectPrinterEvent>(_onSelectPrinter);
    on<ConnectPrinterEvent>(_onConnectPrinter);
    on<DisconnectPrinterEvent>(_onDisconnectPrinter);
    on<StartMonitoringEvent>(
      _onStartMonitoring,
      transformer: _debounceTransformer(),
    );
    on<StopMonitoringEvent>(_onStopMonitoring);
    on<CheckStatusEvent>(_onCheckStatus);
    on<StatusUpdatedEvent>(_onStatusUpdated);
    on<ClearErrorEvent>(_onClearError);
    on<ResetPrinterEvent>(_onResetPrinter);
  }

  // ==================== HANDLERS DE EVENTOS ====================

  Future<void> _onLoadPrinters(
    LoadPrintersEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));

    try {
      final printers = await _printerService.getAvailablePrinters();

      if (printers.isEmpty) {
        emit(
          state.copyWith(
            availablePrinters: [],
            errorMessage: 'No se encontraron impresoras conectadas',
            isLoading: false,
          ),
        );
      } else {
        emit(
          state.copyWith(
            availablePrinters: printers,
            isLoading: false,
            clearError: true,
          ),
        );
      }
    } catch (e) {
      emit(
        state.copyWith(
          errorMessage: 'Error al buscar impresoras: $e',
          isLoading: false,
        ),
      );
    }
  }

  Future<void> _onSelectPrinter(
    SelectPrinterEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    final printer = state.availablePrinters.firstWhere(
      (p) => p.devicePath == event.devicePath,
    );

    emit(state.copyWith(selectedPrinter: printer, clearError: true));
  }

  Future<void> _onConnectPrinter(
    ConnectPrinterEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    if (state.selectedPrinter == null) {
      emit(state.copyWith(errorMessage: 'Seleccione una impresora primero'));
      return;
    }

    emit(
      state.copyWith(
        connectionStatus: PrinterConnectionStatus.connecting,
        isLoading: true,
      ),
    );

    try {
      final success = await _printerService.connect(
        state.selectedPrinter!.devicePath,
      );

      if (success) {
        // Verificar estado inmediatamente después de conectar
        final status = await _printerService.checkStatus();

        emit(
          state.copyWith(
            connectionStatus: PrinterConnectionStatus.connected,
            printerStatus: status,
            isLoading: false,
            clearError: true,
          ),
        );

        // Iniciar monitoreo automático
        add(const StartMonitoringEvent());
      } else {
        emit(
          state.copyWith(
            connectionStatus: PrinterConnectionStatus.error,
            errorMessage: 'No se pudo conectar con la impresora',
            isLoading: false,
          ),
        );
      }
    } catch (e) {
      emit(
        state.copyWith(
          connectionStatus: PrinterConnectionStatus.error,
          errorMessage: 'Error al conectar: $e',
          isLoading: false,
        ),
      );
    }
  }

  Future<void> _onDisconnectPrinter(
    DisconnectPrinterEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    // Detener monitoreo
    add(StopMonitoringEvent());

    emit(state.copyWith(isLoading: true));

    try {
      await _printerService.disconnect();

      emit(
        state.copyWith(
          connectionStatus: PrinterConnectionStatus.disconnected,
          printerStatus: null,
          isLoading: false,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          errorMessage: 'Error al desconectar: $e',
          isLoading: false,
        ),
      );
    }
  }

  Future<void> _onStartMonitoring(
    StartMonitoringEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    if (state.isMonitoring) return;

    emit(state.copyWith(isMonitoring: true));

    // Verificar estado inmediatamente
    add(CheckStatusEvent());

    // Iniciar timer periódico
    _monitoringTimer?.cancel();
    _monitoringTimer = Timer.periodic(event.interval, (timer) {
      if (state.connectionStatus == PrinterConnectionStatus.connected) {
        add(CheckStatusEvent());
      }
    });
  }

  Future<void> _onStopMonitoring(
    StopMonitoringEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    _monitoringTimer?.cancel();
    _monitoringTimer = null;

    emit(state.copyWith(isMonitoring: false));
  }

  Future<void> _onCheckStatus(
    CheckStatusEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    if (state.connectionStatus != PrinterConnectionStatus.connected) {
      return;
    }

    try {
      final status = await _printerService.checkStatus();
      add(StatusUpdatedEvent(status));
    } catch (e) {
      emit(state.copyWith(errorMessage: 'Error al verificar estado: $e'));
    }
  }

  Future<void> _onStatusUpdated(
    StatusUpdatedEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    final status = event.status as PrinterStatus;

    emit(state.copyWith(printerStatus: status, clearError: !status.hasError));

    // Si hay un error crítico, notificar
    if (status.hasError && status.errorType != null) {
      _handlePrinterError(status.errorType!, emit);
    }
  }

  Future<void> _onClearError(
    ClearErrorEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    emit(state.copyWith(clearError: true));
  }

  Future<void> _onResetPrinter(
    ResetPrinterEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    add(StopMonitoringEvent());
    add(DisconnectPrinterEvent());

    await Future.delayed(const Duration(milliseconds: 500));

    add(LoadPrintersEvent());
  }

  // ==================== MÉTODOS PÚBLICOS ====================

  /// Verifica estado antes de un punto crítico (retorna true si está OK)
  Future<bool> validateBeforeCriticalPoint(String checkpointName) async {
    if (state.connectionStatus != PrinterConnectionStatus.connected) {
      return false;
    }

    try {
      final status = await _printerService.checkStatus();
      add(StatusUpdatedEvent(status));
      return status.isReadyToPrint;
    } catch (e) {
      return false;
    }
  }

  // ==================== MÉTODOS PRIVADOS ====================

  void _handlePrinterError(
    PrinterErrorType errorType,
    Emitter<PrinterBlocState> emit,
  ) {
    // Aquí puedes agregar lógica adicional según el tipo de error
    // Por ejemplo, detener monitoreo si el dispositivo no está disponible
    if (errorType == PrinterErrorType.deviceNotFound) {
      add(StopMonitoringEvent());
      emit(
        state.copyWith(connectionStatus: PrinterConnectionStatus.disconnected),
      );
    }
  }

  EventTransformer<T> _debounceTransformer<T>() {
    return (events, mapper) {
      return events
          .debounceTime(const Duration(milliseconds: 300))
          .switchMap(mapper);
    };
  }

  @override
  Future<void> close() {
    _monitoringTimer?.cancel();
    _printerService.disconnect();
    return super.close();
  }
}
