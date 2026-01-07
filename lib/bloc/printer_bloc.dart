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

  // Reconexión automática (cuando se apaga/enciende la impresora)
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  int _noResponseCount = 0;

  static const Duration _reconnectMinDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 10);

  PrinterBloc({PrinterService? printerService})
    : _printerService = printerService ?? PrinterService(),
      super(PrinterBlocState.initial()) {
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
    on<AutoReconnectTickEvent>(_onAutoReconnectTick);
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
    final selected = state.availablePrinters.firstWhere(
      (p) => p.devicePath == event.devicePath,
    );

    emit(state.copyWith(selectedPrinter: selected, clearError: true));
  }

  Future<void> _onConnectPrinter(
    ConnectPrinterEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    if (state.selectedPrinter == null) {
      emit(state.copyWith(errorMessage: 'Seleccione una impresora primero'));
      return;
    }

    _stopAutoReconnect();

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
    // Detener monitoreo y reconexión
    add(StopMonitoringEvent());
    _stopAutoReconnect();

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

  Future<void> _onAutoReconnectTick(
    AutoReconnectTickEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    // Si ya reconectó, cortar
    if (state.connectionStatus == PrinterConnectionStatus.connected) {
      _stopAutoReconnect();
      return;
    }

    final selected = state.selectedPrinter;
    if (selected == null) {
      _stopAutoReconnect();
      return;
    }

    // Evitar solaparse con otra conexión
    if (state.connectionStatus == PrinterConnectionStatus.connecting ||
        state.isLoading) {
      _scheduleNextReconnect();
      return;
    }

    try {
      final printers = await _printerService.getAvailablePrinters();

      if (printers.isEmpty) {
        _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 20);
        _scheduleNextReconnect();
        return;
      }

      // Preferir el mismo devicePath; si cambió y hay 1 sola impresora, usar esa
      PrinterDevice? target;
      for (final p in printers) {
        if (p.devicePath == selected.devicePath) {
          target = p;
          break;
        }
      }
      target ??= printers.length == 1 ? printers.first : null;

      if (target == null) {
        // Hay varias impresoras y la seleccionada no está: no adivinar
        emit(
          state.copyWith(
            availablePrinters: printers,
            connectionStatus: PrinterConnectionStatus.disconnected,
            isLoading: false,
            errorMessage:
                'Impresora desconectada. Se detectaron múltiples impresoras; seleccione una para reconectar.',
          ),
        );
        _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 20);
        _scheduleNextReconnect();
        return;
      }

      emit(
        state.copyWith(
          availablePrinters: printers,
          selectedPrinter: target,
          connectionStatus: PrinterConnectionStatus.connecting,
          isLoading: false,
        ),
      );

      final ok = await _printerService.connect(target.devicePath);

      if (!ok) {
        emit(
          state.copyWith(
            connectionStatus: PrinterConnectionStatus.disconnected,
            isLoading: false,
          ),
        );
        _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 20);
        _scheduleNextReconnect();
        return;
      }

      final status = await _printerService.checkStatus();

      emit(
        state.copyWith(
          connectionStatus: PrinterConnectionStatus.connected,
          printerStatus: status,
          isLoading: false,
          clearError: true,
        ),
      );

      _stopAutoReconnect();
      add(const StartMonitoringEvent());
    } catch (_) {
      _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 20);
      _scheduleNextReconnect();
    }
  }

  Future<void> _onStatusUpdated(
    StatusUpdatedEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    final status = event.status as PrinterStatus;

    emit(state.copyWith(printerStatus: status, clearError: !status.hasError));

    if (!status.hasError || status.errorType == null) {
      _noResponseCount = 0;
      // Si reconectó, apagar cualquier loop
      if (state.connectionStatus == PrinterConnectionStatus.connected) {
        _stopAutoReconnect();
      }
      return;
    }

    final errorType = status.errorType!;

    // Caso típico cuando se apaga la impresora:
    // - el plugin devuelve "no responde" / comunicación fallida o device desaparece.
    if (errorType == PrinterErrorType.deviceNotFound ||
        errorType == PrinterErrorType.communicationError) {
      _markConnectionLost(emit);
      return;
    }

    // Si se repite "no responde" 2 veces seguidas, tratarlo como desconexión
    if (errorType == PrinterErrorType.offline &&
        status.errorMessage == 'Impresora no responde') {
      _noResponseCount++;
      if (_noResponseCount >= 2) {
        _markConnectionLost(emit);
        return;
      }
    } else {
      _noResponseCount = 0;
    }

    // Otros errores (papel, tapa, etc.)
    _handlePrinterError(errorType, emit);
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
    _stopAutoReconnect();
    add(DisconnectPrinterEvent());

    await Future.delayed(const Duration(milliseconds: 500));

    add(LoadPrintersEvent());
  }

  // ==================== HELPERS ====================

  /// Verifica estado antes de un punto crítico (retorna true si está OK)
  Future<bool> validateBeforeCriticalPoint(String checkpointName) async {
    if (state.connectionStatus != PrinterConnectionStatus.connected) {
      // Si estás en disconnected, dispara un intento de reconexión
      add(const AutoReconnectTickEvent());
      return false;
    }

    try {
      final status = await _printerService.checkStatus();
      add(
        StatusUpdatedEvent(status),
      ); // aquí es donde se activará auto-reconnect si aplica
      return status.isReadyToPrint;
    } catch (_) {
      return false;
    }
  }

  void _startAutoReconnect() {
    if (_reconnectTimer != null) return;
    _reconnectAttempt = 0;
    _scheduleNextReconnect();
  }

  void _scheduleNextReconnect() {
    _reconnectTimer?.cancel();

    final ms = (_reconnectMinDelay.inMilliseconds * (1 << _reconnectAttempt))
        .clamp(
          _reconnectMinDelay.inMilliseconds,
          _reconnectMaxDelay.inMilliseconds,
        );

    _reconnectTimer = Timer(Duration(milliseconds: ms), () {
      add(const AutoReconnectTickEvent());
    });
  }

  void _stopAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _noResponseCount = 0;
  }

  void _markConnectionLost(Emitter<PrinterBlocState> emit) {
    add(StopMonitoringEvent());

    emit(
      state.copyWith(
        connectionStatus: PrinterConnectionStatus.disconnected,
        isLoading: false,
      ),
    );

    _startAutoReconnect();
  }

  void _handlePrinterError(
    PrinterErrorType errorType,
    Emitter<PrinterBlocState> emit,
  ) {
    // Dejar lugar para lógica específica por tipo de error.
    // Los casos de desconexión se manejan en _onStatusUpdated.
    if (errorType == PrinterErrorType.deviceNotFound ||
        errorType == PrinterErrorType.communicationError) {
      _markConnectionLost(emit);
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
  Future<void> close() async {
    _monitoringTimer?.cancel();
    _stopAutoReconnect();
    await _printerService.disconnect();
    return super.close();
  }
}
