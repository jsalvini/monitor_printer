import 'dart:async';
import 'dart:developer' as dev;
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

  // Auto-conexión al iniciar: conectar a la primera impresora disponible
  bool _startupAutoConnectHandled = false;

  static const Duration _reconnectMinDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 10);

  void _log(String message) {
    dev.log('🖨️ $message', name: 'PrinterBloc');
  }

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
    on<AutoReconnectTickEvent>(_onAutoReconnectTick);
    on<StatusUpdatedEvent>(_onStatusUpdated);
    on<ClearErrorEvent>(_onClearError);
    on<ResetPrinterEvent>(_onResetPrinter);

    // Al iniciar, listar impresoras e intentar conectar a la primera disponible
    add(LoadPrintersEvent());
  }

  // ==================== HANDLERS DE EVENTOS ====================

  Future<void> _onLoadPrinters(
    LoadPrintersEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    emit(state.copyWith(isLoading: true));

    try {
      final printers = await _printerService.getAvailablePrinters();
      _log('USB printers detectadas: ${printers.length}');

      if (printers.isEmpty) {
        emit(
          state.copyWith(
            availablePrinters: [],
            errorMessage: 'No se encontraron impresoras conectadas',
            isLoading: false,
          ),
        );

        // ✅ Solo una vez al arranque: empezar a reintentar hasta que aparezca una
        if (!_startupAutoConnectHandled) {
          _startupAutoConnectHandled = true;
          _startAutoReconnect(); // tu tick ya conecta a la primera si selected == null
        }
        return;
      }

      final shouldAutoConnect =
          !_startupAutoConnectHandled &&
          state.connectionStatus == PrinterConnectionStatus.disconnected &&
          state.selectedPrinter == null;

      final selectedForUi = shouldAutoConnect
          ? printers.first
          : state.selectedPrinter;

      emit(
        state.copyWith(
          availablePrinters: printers,
          selectedPrinter: selectedForUi,
          isLoading: false,
          clearError: true,
        ),
      );

      if (shouldAutoConnect) {
        _startupAutoConnectHandled = true;
        _log('Auto-connect inicio: conectando a ${printers.first.devicePath}');
        add(ConnectPrinterEvent()); // conecta e inicia monitoreo
      } else if (!_startupAutoConnectHandled) {
        // Consume la bandera igualmente (para que no haga autoconnect en reloads manuales)
        _startupAutoConnectHandled = true;
      }
    } catch (e) {
      emit(
        state.copyWith(
          errorMessage: 'Error al buscar impresoras: $e',
          isLoading: false,
        ),
      );

      // Si falla al inicio, también podés optar por reintentar (solo una vez)
      if (!_startupAutoConnectHandled) {
        _startupAutoConnectHandled = true;
        _startAutoReconnect();
      }
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
    _log(
      'Impresora seleccionada: ${printer.devicePath} (${printer.displayName})',
    );
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

    _log('Conectando a: ${state.selectedPrinter!.devicePath}');

    try {
      final success = await _printerService.connect(
        state.selectedPrinter!.devicePath,
      );

      if (success) {
        _log('Conexión OK');
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
        _log('Conexión fallida');
        emit(
          state.copyWith(
            connectionStatus: PrinterConnectionStatus.error,
            errorMessage: 'No se pudo conectar con la impresora',
            isLoading: false,
          ),
        );

        // Reintentar automáticamente (útil en inicio o si el puerto estaba en transición)
        _startAutoReconnect();
      }
    } catch (e) {
      emit(
        state.copyWith(
          connectionStatus: PrinterConnectionStatus.error,
          errorMessage: 'Error al conectar: $e',
          isLoading: false,
        ),
      );

      _startAutoReconnect();
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
      _log('Desconectado');

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
    _log('Monitoreo iniciado (polling)');

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
    _log('Monitoreo detenido');
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
    _log('AutoReconnectTick');
    // Si ya reconectó, cortar
    if (state.connectionStatus == PrinterConnectionStatus.connected) {
      _stopAutoReconnect();
      return;
    }

    final selected = state.selectedPrinter;
    // Si no hay impresora seleccionada (por ejemplo al iniciar),
    // intentar conectar a la primera disponible cuando aparezca.
    if (selected == null) {
      try {
        final printers = await _printerService.getAvailablePrinters();

        if (printers.isEmpty) {
          _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 20);
          _scheduleNextReconnect();
          return;
        }

        final target = printers.first;

        emit(
          state.copyWith(
            availablePrinters: printers,
            selectedPrinter: target,
            connectionStatus: PrinterConnectionStatus.connecting,
            isLoading: false,
          ),
        );

        _log(
          'Auto-reconnect (sin selección): intentando conectar a ${target.devicePath}',
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
        return;
      } catch (_) {
        _reconnectAttempt = (_reconnectAttempt + 1).clamp(0, 20);
        _scheduleNextReconnect();
        return;
      }
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
        _log('No hay impresoras detectadas (reintentando)');
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

      _log('Intentando reconectar a: ${target.devicePath}');

      final ok = await _printerService.connect(target.devicePath);

      if (!ok) {
        _log('Reconexión fallida');
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

      _log('Reconexión OK');

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

    _log('Auto-reconnect en ${ms}ms (intento $_reconnectAttempt)');

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
    _log('Conexión perdida -> desconectado y auto-reconnect');
    add(StopMonitoringEvent());

    emit(
      state.copyWith(
        connectionStatus: PrinterConnectionStatus.disconnected,
        isLoading: false,
      ),
    );

    _startAutoReconnect();
  }

  Future<void> _onStatusUpdated(
    StatusUpdatedEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    final status = event.status as PrinterStatus;

    emit(state.copyWith(printerStatus: status, clearError: !status.hasError));

    if (!status.hasError || status.errorType == null) {
      // _log('Estado OK');
      _noResponseCount = 0;
      // Si reconectó, apagar cualquier loop
      if (state.connectionStatus == PrinterConnectionStatus.connected) {
        _stopAutoReconnect();
      }
      return;
    }

    final errorType = status.errorType!;
    _log('Estado con error: $errorType - ${status.errorMessage}');

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
    _startupAutoConnectHandled = false;
    add(StopMonitoringEvent());
    _stopAutoReconnect();
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
