import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:rxdart/rxdart.dart';
import '../models/printer_status.dart';
import '../services/printer_service.dart';
import 'printer_event.dart';
import 'printer_state.dart';
import 'dart:typed_data';

/// BLoC que gestiona el estado y lógica de la impresora
/// Optimizado para terminales de autoservicio con alta disponibilidad
class PrinterBloc extends Bloc<PrinterEvent, PrinterBlocState> {
  final PrinterService _printerService;
  Timer? _monitoringTimer;
  Timer? _reconnectTimer;
  Timer? _printClearTimer;

  int _reconnectAttempt = 0;
  int _noResponseCount = 0;
  bool _startupAutoConnectHandled = false;

  static const Duration _reconnectMinDelay = Duration(milliseconds: 500);
  static const Duration _reconnectMaxDelay = Duration(seconds: 10);

  void _log(String message) {
    dev.log('🖨️ $message', name: 'PrinterBloc');
  }

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
    on<PrintTicketEvent>(_onPrintTicket);
    on<ClearPrintStatusEvent>(_onClearPrintStatus);

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

        if (!_startupAutoConnectHandled) {
          _startupAutoConnectHandled = true;
          _startAutoReconnect();
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
        add(ConnectPrinterEvent());
      } else if (!_startupAutoConnectHandled) {
        _startupAutoConnectHandled = true;
      }
    } catch (e) {
      emit(
        state.copyWith(
          errorMessage: 'Error al buscar impresoras: $e',
          isLoading: false,
        ),
      );

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
        final status = await _printerService.checkStatus();

        emit(
          state.copyWith(
            connectionStatus: PrinterConnectionStatus.connected,
            printerStatus: status,
            isLoading: false,
            clearError: true,
          ),
        );

        // Resetear contadores con conexion exitosa
        _noResponseCount = 0;
        _reconnectAttempt = 0;

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
    _log('Monitoreo iniciado (polling cada ${event.interval.inSeconds}s)');

    add(CheckStatusEvent());

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
    _log('AutoReconnectTick (intento ${_reconnectAttempt + 1})');

    if (state.connectionStatus == PrinterConnectionStatus.connected) {
      _stopAutoReconnect();
      return;
    }

    final selected = state.selectedPrinter;

    // Sin selección: intentar con la primera disponible
    if (selected == null) {
      try {
        final printers = await _printerService.getAvailablePrinters();

        if (printers.isEmpty) {
          _reconnectAttempt++;
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

        _log('Auto-reconnect: conectando a ${target.devicePath}');
        final ok = await _printerService.connect(target.devicePath);

        if (!ok) {
          emit(
            state.copyWith(
              connectionStatus: PrinterConnectionStatus.disconnected,
              isLoading: false,
            ),
          );
          _reconnectAttempt++;
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
        _reconnectAttempt++;
        _scheduleNextReconnect();
        return;
      }
    }

    // Con selección: intentar reconectar al mismo dispositivo
    if (state.connectionStatus == PrinterConnectionStatus.connecting ||
        state.isLoading) {
      _scheduleNextReconnect();
      return;
    }

    try {
      final printers = await _printerService.getAvailablePrinters();

      if (printers.isEmpty) {
        _log(
          'No hay impresoras detectadas (reintentando en ${_getNextDelaySeconds()}s)',
        );
        _reconnectAttempt++;
        _scheduleNextReconnect();
        return;
      }

      PrinterDevice? target;
      for (final p in printers) {
        if (p.devicePath == selected.devicePath) {
          target = p;
          break;
        }
      }
      target ??= printers.length == 1 ? printers.first : null;

      if (target == null) {
        emit(
          state.copyWith(
            availablePrinters: printers,
            connectionStatus: PrinterConnectionStatus.disconnected,
            isLoading: false,
            errorMessage:
                'Impresora desconectada. Se detectaron múltiples impresoras; seleccione una.',
          ),
        );
        _reconnectAttempt++;
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
        _log('Reconexión fallida (reintentando en ${_getNextDelaySeconds()}s)');
        emit(
          state.copyWith(
            connectionStatus: PrinterConnectionStatus.disconnected,
            isLoading: false,
          ),
        );
        _reconnectAttempt++;
        _scheduleNextReconnect();
        return;
      }

      final status = await _printerService.checkStatus();

      _log('Reconexión exitosa después de ${_reconnectAttempt + 1} intentos');

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
    } catch (e) {
      _log('Error en reconexión: $e (reintentando)');
      _reconnectAttempt++;
      _scheduleNextReconnect();
    }
  }

  Future<void> _onPrintTicket(
    PrintTicketEvent event,
    Emitter<PrinterBlocState> emit,
  ) async {
    // 1. Prevenir doble click
    if (state.printStatus == PrintStatus.printing) {
      _log('PrintTest: ya hay impresión en curso');
      return;
    }

    // 2. Verificar estado inicial
    if (state.connectionStatus != PrinterConnectionStatus.connected) {
      _log('PrintTest: no conectada');
      emit(
        state.copyWith(
          printStatus: PrintStatus.error,
          printMessage: 'No hay impresora conectada',
        ),
      );
      _scheduleClearPrintChip();
      return;
    }

    _printClearTimer?.cancel();
    emit(state.copyWith(printStatus: PrintStatus.printing, printMessage: null));

    _log('PrintTest: iniciando...');

    try {
      // 3. Validar estado (operación async)
      final ready = await validateBeforeCriticalPoint('print_test');

      if (!ready) {
        _log('PrintTest: impresora no lista');
        emit(
          state.copyWith(
            printStatus: PrintStatus.error,
            printMessage: 'Impresora no lista (papel/tapa/offline)',
          ),
        );
        _scheduleClearPrintChip();
        return;
      }

      // 4. CRÍTICO: Verificar que el estado no cambió durante la operación async
      if (state.connectionStatus != PrinterConnectionStatus.connected) {
        _log('PrintTest: desconectada durante validación');
        emit(
          state.copyWith(
            printStatus: PrintStatus.error,
            printMessage: 'Impresora desconectada durante validación',
          ),
        );
        _scheduleClearPrintChip();
        return;
      }

      // 5. Verificar que el servicio sigue conectado
      if (!_printerService.isConnected) {
        _log('PrintTest: servicio desconectado');
        emit(
          state.copyWith(
            printStatus: PrintStatus.error,
            printMessage: 'Conexión perdida',
          ),
        );
        _scheduleClearPrintChip();
        return;
      }

      // 6. Todo OK, proceder a imprimir
      final data = _buildSampleTicket();
      final ok = await _printerService.sendRawData(data);

      if (ok) {
        _log('PrintTest: OK');
        emit(
          state.copyWith(
            printStatus: PrintStatus.success,
            printMessage: 'Impresión enviada',
          ),
        );
      } else {
        _log('PrintTest: FAIL (sendRawData false)');
        emit(
          state.copyWith(
            printStatus: PrintStatus.error,
            printMessage: 'No se pudo enviar el ticket',
          ),
        );
      }
    } catch (e) {
      _log('PrintTest: exception $e');
      emit(
        state.copyWith(
          printStatus: PrintStatus.error,
          printMessage: 'Error imprimiendo: $e',
        ),
      );
    } finally {
      _scheduleClearPrintChip();
    }
  }

  void _scheduleClearPrintChip() {
    _printClearTimer?.cancel();
    _printClearTimer = Timer(const Duration(seconds: 3), () {
      add(const ClearPrintStatusEvent());
    });
  }

  void _onClearPrintStatus(
    ClearPrintStatusEvent event,
    Emitter<PrinterBlocState> emit,
  ) {
    emit(
      state.copyWith(printStatus: PrintStatus.idle, clearPrintMessage: true),
    );
  }

  void _startAutoReconnect() {
    if (_reconnectTimer != null) {
      _log('Auto-reconnect ya está activo');
      return;
    }
    _reconnectAttempt = 0;
    _scheduleNextReconnect();
  }

  void _scheduleNextReconnect() {
    _reconnectTimer?.cancel();

    // En autoservicio, SIEMPRE reintenta
    final ms = (_reconnectMinDelay.inMilliseconds * (1 << _reconnectAttempt))
        .clamp(
          _reconnectMinDelay.inMilliseconds,
          _reconnectMaxDelay.inMilliseconds,
        );

    _log('Auto-reconnect en ${ms ~/ 1000}s (intento ${_reconnectAttempt + 1})');

    _reconnectTimer = Timer(Duration(milliseconds: ms), () {
      add(const AutoReconnectTickEvent());
    });
  }

  int _getNextDelaySeconds() {
    final ms = (_reconnectMinDelay.inMilliseconds * (1 << _reconnectAttempt))
        .clamp(
          _reconnectMinDelay.inMilliseconds,
          _reconnectMaxDelay.inMilliseconds,
        );
    return ms ~/ 1000;
  }

  void _stopAutoReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _noResponseCount = 0;
  }

  void _markConnectionLost(Emitter<PrinterBlocState> emit) {
    _log('Conexión perdida -> desconectado y auto-reconnect indefinido');
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
      // Resetear contador cuando la impresora responde OK
      _noResponseCount = 0;

      if (state.connectionStatus == PrinterConnectionStatus.connected) {
        _stopAutoReconnect();
      }
      return;
    }

    final errorType = status.errorType!;
    _log('Estado con error: $errorType - ${status.errorMessage}');

    if (errorType == PrinterErrorType.deviceNotFound ||
        errorType == PrinterErrorType.communicationError) {
      _markConnectionLost(emit);
      return;
    }

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

  Uint8List _buildSampleTicket() {
    final List<int> commands = [];

    commands.addAll([0x1B, 0x40]);
    commands.addAll([0x1B, 0x61, 0x01]);
    commands.addAll('IMPRESION DE PRUEBA\n'.codeUnits);

    commands.addAll([0x1B, 0x45, 0x01]);
    commands.addAll('MONITOR PRINTER\n'.codeUnits);
    commands.addAll([0x1B, 0x45, 0x00]);

    commands.addAll('\n'.codeUnits);
    commands.addAll('--------------------------------\n'.codeUnits);

    commands.addAll([0x1B, 0x61, 0x00]);

    final now = DateTime.now();
    commands.addAll(
      'Fecha: ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}\n'
          .codeUnits,
    );
    commands.addAll(
      'Hora: ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}\n'
          .codeUnits,
    );
    commands.addAll('\n'.codeUnits);

    commands.addAll('Si ves este ticket, la\n'.codeUnits);
    commands.addAll('conexion y el envio OK.\n'.codeUnits);

    commands.addAll('\n\n\n'.codeUnits);
    commands.addAll([0x1D, 0x56, 0x42, 0x00]);

    return Uint8List.fromList(commands);
  }

  void _handlePrinterError(
    PrinterErrorType errorType,
    Emitter<PrinterBlocState> emit,
  ) {
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
    _printClearTimer?.cancel();
    _monitoringTimer?.cancel();
    _stopAutoReconnect();
    await _printerService.disconnect();
    return super.close();
  }
}
