import 'dart:async';
import 'dart:developer' as dev;
import 'package:flutter/foundation.dart';
import 'package:ti_printer_plugin/ti_printer_plugin.dart';
import '../models/printer_status.dart';

/// Servicio corregido para EPSON TM-T20IIIL
/// Incluye logs con print() para modo release y corrección de interpretación de bits
class PrinterService {
  final TiPrinterPlugin _plugin;
  String? _currentDevicePath;
  bool _isEpsonPrinter = false;

  PrinterService() : _plugin = TiPrinterPlugin();

  // Comandos DLE EOT
  static final Uint8List _cmdEot1 = Uint8List.fromList([
    0x10,
    0x04,
    0x01,
  ]); // Printer status
  static final Uint8List _cmdEot2 = Uint8List.fromList([
    0x10,
    0x04,
    0x02,
  ]); // Offline cause
  static final Uint8List _cmdEot4 = Uint8List.fromList([
    0x10,
    0x04,
    0x04,
  ]); // Roll paper sensor

  final Stopwatch _sinceStart = Stopwatch()..start();
  int _logSeq = 0;
  int _checkSeq = 0;

  Future<void> _usbQueue = Future.value();

  Future<T> _withUsbLock<T>(Future<T> Function() action) {
    final c = Completer<T>();
    _usbQueue = _usbQueue.then((_) async {
      try {
        c.complete(await action());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  void _log(String message) {
    final now = DateTime.now().toIso8601String(); // incluye ms y zona
    final ms = _sinceStart.elapsedMilliseconds.toString().padLeft(7, '0');
    // Usar print() en lugar de dev.log() para que aparezca en release
    if (kDebugMode) {
      print('🖨️ [$now|+$ms ms|#${_logSeq++}] [PrinterService] $message');
    }
    dev.log(
      '🖨️ [$now|+$ms ms|#${_logSeq++}] $message',
      name: 'PrinterService',
    );
  }

  /// Obtiene lista de impresoras USB disponibles
  Future<List<PrinterDevice>> getAvailablePrinters() async {
    try {
      final devices = await _plugin.getUsbPrinters();
      _log('getUsbPrinters -> ${devices.length} dispositivos');
      return devices.map((devicePath) {
        final name = _extractDeviceName(devicePath);
        return PrinterDevice(
          devicePath: devicePath,
          displayName: name,
          isConnected: devicePath == _currentDevicePath,
        );
      }).toList();
    } catch (e) {
      throw PrinterServiceException('Error al obtener impresoras: $e');
    }
  }

  /// Conecta con una impresora específica
  Future<bool> connect(String devicePath) async {
    try {
      _log('connect($devicePath)');

      await _safeCloseUsbPort();
      _currentDevicePath = null;
      _isEpsonPrinter = false;

      final success = await _plugin.openUsbPort(devicePath);
      _log('openUsbPort -> $success');

      if (success == true) {
        _currentDevicePath = devicePath;

        // Pequeño delay después de conectar
        await Future.delayed(const Duration(milliseconds: 200));

        // Detectar tipo de impresora
        await _detectPrinterType();

        return true;
      }

      return false;
    } catch (e) {
      throw PrinterServiceException('Error al conectar con impresora: $e');
    }
  }

  /// Detecta el tipo de impresora
  Future<void> _detectPrinterType() async {
    try {
      // GS I 1 - Obtener ID de modelo
      final printerIdCmd = Uint8List.fromList([0x1D, 0x49, 0x01]);

      await Future.delayed(const Duration(milliseconds: 100));

      final response = await _plugin.readStatusUsb(printerIdCmd);

      if (response != null && response.isNotEmpty) {
        final modelId = String.fromCharCodes(response);
        _log('Modelo detectado: $modelId');

        if (modelId.contains('TM-') || modelId.contains('EPSON')) {
          _isEpsonPrinter = true;
          _log('⭐ Impresora EPSON detectada - Usando interpretación EPSON');
        }
      }
    } catch (e) {
      _log('No se pudo detectar tipo (usando modo genérico): $e');
    }
  }

  /// Desconecta de la impresora actual
  Future<void> disconnect() async {
    try {
      _log('disconnect()');
      await _safeCloseUsbPort();
    } catch (e) {
      _log('disconnect error (ignorado): $e');
    } finally {
      _currentDevicePath = null;
      _isEpsonPrinter = false;
    }
  }

  /// Lee el estado completo de la impresora
  Future<PrinterStatus> checkStatus() {
    return _withUsbLock(() async {
      final devicePath = _currentDevicePath;

      final callId = ++_checkSeq;
      final sw = Stopwatch()..start();

      if (devicePath == null) {
        return PrinterStatus.withError(
          PrinterErrorType.deviceNotFound,
          'No hay impresora conectada',
        );
      }

      try {
        _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        _log('📊 CONSULTA DE ESTADO (Epson-safe)');

        // 1) EOT1
        final onlineByte = await _readStatusByteWithRetry(
          _cmdEot1,
          retries: 2,
          tag: 'EOT1',
        );
        _log(
          'Online (DLE EOT 1): ${onlineByte == null ? 'null' : '0x${onlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()}'}',
        );

        // Fallback: si NO responde EOT1, probá EOT2/EOT4 antes de decidir desconectado.
        if (onlineByte == null) {
          _log('⚠️ EOT1 sin respuesta → probando EOT2/EOT4 para deducir causa');

          final offlineByte = await _readStatusByteWithRetry(
            _cmdEot2,
            retries: 1,
            tag: 'EOT2',
          );
          final paperByte = await _readStatusByteWithRetry(
            _cmdEot4,
            retries: 1,
            tag: 'EOT4',
          );

          _log(
            'Offline (DLE EOT 2): ${offlineByte == null ? 'null' : '0x${offlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()}'}',
          );
          _log(
            'Paper   (DLE EOT 4): ${paperByte == null ? 'null' : '0x${paperByte.toRadixString(16).padLeft(2, '0').toUpperCase()}'}',
          );

          // Si EOT2 llegó, podés detectar tapa/error aunque EOT1 no haya respondido
          if (offlineByte != null) {
            final coverOpen =
                (offlineByte & 0x04) != 0; // EOT2 bit2 (cover open)
            final err = (offlineByte & 0x40) != 0; // EOT2 bit6 (error occurred)
            final paperEndStop =
                (offlineByte & 0x20) != 0; // EOT2 bit5 (paper-end stop)

            if (coverOpen) {
              return PrinterStatus.withError(
                PrinterErrorType.coverOpen,
                'La tapa de la impresora está abierta',
              );
            }
            if (err) {
              return PrinterStatus.withError(
                PrinterErrorType.communicationError,
                'Error de impresora (offline)',
              );
            }
            if (paperEndStop) {
              return PrinterStatus.withError(
                PrinterErrorType.paperOut,
                'Impresora detenida por fin de papel',
              );
            }
          }

          // Si EOT4 llegó, podés detectar paper-out
          if (paperByte != null) {
            final paperOut = (paperByte & 0x60) == 0x60; // EOT4 bits 5&6 == 11
            if (paperOut) {
              return PrinterStatus.withError(
                PrinterErrorType.paperOut,
                'Sin papel en la impresora',
              );
            }
          }

          // Si nada respondió: distinguir offline “sin respuesta” vs desconectado real
          final present = await _isDevicePresent(devicePath);
          if (!present) {
            _log('❌ Dispositivo no presente -> desconectado');
            await _safeCloseUsbPort();
            _currentDevicePath = null;
            return PrinterStatus.withError(
              PrinterErrorType.deviceNotFound,
              'Impresora desconectada',
            );
          }

          // Está presente, pero no responde (típico cuando tapa abierta / busy condition)
          return PrinterStatus.withError(
            PrinterErrorType.offline,
            'Impresora offline (sin respuesta a estado). Verificá tapa/papel.',
          );
        }

        // EOT1 respondió → seguimos normal
        final isOnline = (onlineByte & 0x08) == 0; // EOT1 bit3 (online/offline)
        _log('   └─ Bit3 Online: ${isOnline ? '✅ Online' : '❌ Offline'}');

        final paperByte = await _readStatusByteWithRetry(
          _cmdEot4,
          retries: 1,
          tag: 'EOT4',
        );
        _log(
          'Paper (DLE EOT 4): ${paperByte == null ? 'null' : '0x${paperByte.toRadixString(16).padLeft(2, '0').toUpperCase()}'}',
        );

        int? offlineByte;
        if (!isOnline) {
          offlineByte = await _readStatusByteWithRetry(
            _cmdEot2,
            retries: 1,
            tag: 'EOT2',
          );
          _log(
            'Offline (DLE EOT 2): ${offlineByte == null ? 'null' : '0x${offlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()}'}',
          );
        } else {
          _log('Offline (DLE EOT 2): (omitido porque está Online)');
        }

        return _interpretBytes(
          onlineByte: onlineByte,
          paperByte: paperByte,
          offlineByte: offlineByte,
        );
      } catch (e) {
        final present = await _isDevicePresent(devicePath);
        if (!present) {
          _log('❌ Exception + device ausente -> desconectado ($e)');
          await _safeCloseUsbPort();
          _currentDevicePath = null;
          return PrinterStatus.withError(
            PrinterErrorType.deviceNotFound,
            'Impresora desconectada',
          );
        }

        _log('❌ Error de comunicación: $e');
        return PrinterStatus.withError(
          PrinterErrorType.communicationError,
          'Error de comunicación con impresora: $e',
        );
      } finally {
        _log('📊 [#$callId] FIN checkStatus() ${sw.elapsedMilliseconds}ms');
        _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      }
    });
  }

  /// Envía datos crudos a la impresora
  Future<bool> sendRawData(Uint8List data) async {
    if (_currentDevicePath == null) {
      throw PrinterServiceException('No hay impresora conectada');
    }

    try {
      final success = await _plugin.sendCommandToUsb(data);
      return success ?? false;
    } catch (e) {
      throw PrinterServiceException('Error al enviar datos: $e');
    }
  }

  bool get isConnected => _currentDevicePath != null;
  String? get currentDevicePath => _currentDevicePath;
  bool get isEpsonPrinter => _isEpsonPrinter;

  // ==================== HELPERS ====================

  Future<void> _safeCloseUsbPort() async {
    try {
      if (_currentDevicePath != null) {
        await _plugin.closeUsbPort();
        _log('Puerto USB cerrado');
      }
    } catch (e) {
      _log('Error al cerrar puerto (ignorado): $e');
    }
  }

  Future<bool> _isDevicePresent(String devicePath) async {
    try {
      final devices = await _plugin.getUsbPrinters();
      return devices.contains(devicePath);
    } catch (_) {
      return false;
    }
  }

  String _formatBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return '(vacío)';
    return bytes
        .map((b) => '0x${b.toRadixString(16).padLeft(2, '0').toUpperCase()}')
        .join(' ');
  }

  String _extractDeviceName(String devicePath) {
    if (devicePath.contains('lp')) {
      final lpNum = devicePath.split('lp').last;
      return 'Impresora USB LP$lpNum';
    } else if (devicePath.contains('ttyUSB')) {
      final usbNum = devicePath.split('ttyUSB').last;
      return 'Puerto Serial USB$usbNum';
    } else if (devicePath.contains('ttyACM')) {
      final acmNum = devicePath.split('ttyACM').last;
      return 'Puerto ACM$acmNum';
    }
    return devicePath.split('/').last.toUpperCase();
  }

  String _toBinaryString(int value) {
    final s = value.toRadixString(2).padLeft(8, '0');
    return '${s.substring(0, 4)} ${s.substring(4, 8)}';
  }

  PrinterStatus _interpretStatus(
    Uint8List? onlineResponse,
    Uint8List? paperResponse,
    Uint8List? offlineResponse,
  ) {
    if (onlineResponse == null || onlineResponse.isEmpty) {
      return PrinterStatus.withError(
        PrinterErrorType.offline,
        'Impresora no responde',
      );
    }

    final onlineByte = onlineResponse[0];
    final paperByte = (paperResponse != null && paperResponse.isNotEmpty)
        ? paperResponse[0]
        : 0x00; // Cambio: default 0x00 en lugar de 0xFF
    final offlineByte = (offlineResponse != null && offlineResponse.isNotEmpty)
        ? offlineResponse[0]
        : 0x00;

    _log('📋 BYTES RECIBIDOS:');
    _log(
      '   Online byte:  0x${onlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()} = ${_toBinaryString(onlineByte)}',
    );
    _log(
      '   Paper byte:   0x${paperByte.toRadixString(16).padLeft(2, '0').toUpperCase()} = ${_toBinaryString(paperByte)}',
    );
    _log(
      '   Offline byte: 0x${offlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()} = ${_toBinaryString(offlineByte)}',
    );

    // INTERPRETACIÓN CORREGIDA PARA EPSON
    bool isOnline;
    bool hasPaper;
    bool isCoverOpen;

    // DLE EOT 1 - Online Status
    // Bit 3: 0 = online, 1 = offline
    // Bit 5: 0 = sin error, 1 = error
    isOnline = (onlineByte & 0x08) == 0;
    final hasOnlineError = (onlineByte & 0x20) != 0;

    _log(
      '   └─ Bit 3 (Online): ${(onlineByte & 0x08) == 0 ? 'Online ✅' : 'Offline ❌'}',
    );
    _log('   └─ Bit 5 (Error):  ${hasOnlineError ? 'Error ❌' : 'Sin error ✅'}');

    // DLE EOT 4 - Paper Status
    // CORRECCIÓN: Para EPSON TM-T20IIIL
    // Valores típicos:
    //   0x00 (00000000) = Papel OK
    //   0x60 (01100000) = Sin papel (bits 5-6)
    //   0x7E (01111110) = Sin papel + otros bits

    // Verificar bits 5 y 6 específicamente
    final bit5 = (paperByte & 0x20) != 0;
    final bit6 = (paperByte & 0x40) != 0;

    // Si AMBOS bits 5 y 6 están en 1, entonces NO hay papel
    // Si alguno es 0, entonces SÍ hay papel
    hasPaper = !(bit5 && bit6);

    _log('   └─ Bit 5: ${bit5 ? '1' : '0'}');
    _log('   └─ Bit 6: ${bit6 ? '1' : '0'}');
    _log('   └─ Paper Status: ${hasPaper ? 'Disponible ✅' : 'Sin papel ❌'}');

    // DLE EOT 2 - Offline Cause
    // Bit 2: 0 = tapa cerrada, 1 = tapa abierta
    // CORRECCIÓN: Verificar también bit 5 que puede indicar error de tapa
    final bit2 = (offlineByte & 0x04) != 0;
    final bit5offline = (offlineByte & 0x20) != 0;

    // La tapa está abierta si el bit 2 está en 1
    // PERO: algunos modelos EPSON usan bit 5 para indicar error relacionado con tapa
    isCoverOpen = bit2;

    _log('   └─ Bit 2 (Cover): ${bit2 ? 'Abierta ❌' : 'Cerrada ✅'}');
    _log('   └─ Bit 5 (Error): ${bit5offline ? 'Error ❌' : 'OK ✅'}');

    // DIAGNÓSTICO ADICIONAL
    _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    _log('📊 ESTADO FINAL INTERPRETADO:');
    _log('   Online:      ${isOnline ? '✅ SÍ' : '❌ NO'}');
    _log('   Papel:       ${hasPaper ? '✅ Disponible' : '❌ Agotado'}');
    _log('   Tapa:        ${isCoverOpen ? '❌ Abierta' : '✅ Cerrada'}');
    _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    // Detectar errores específicos
    if (isCoverOpen) {
      _log('🔴 ERROR: Tapa abierta');
      return PrinterStatus.withError(
        PrinterErrorType.coverOpen,
        'La tapa de la impresora está abierta',
      );
    }

    if (!hasPaper) {
      _log('🟡 ADVERTENCIA: Sin papel');
      return PrinterStatus.withError(
        PrinterErrorType.paperOut,
        'Sin papel en la impresora',
      );
    }

    if (!isOnline) {
      _log('🔴 ERROR: Impresora offline');
      return PrinterStatus.withError(
        PrinterErrorType.offline,
        'Impresora fuera de línea',
      );
    }

    // Estado saludable
    _log('🟢 Estado: SALUDABLE');
    return PrinterStatus(
      isOnline: isOnline,
      hasPaper: hasPaper,
      isCoverOpen: isCoverOpen,
      hasError: false,
      lastChecked: DateTime.now(),
    );
  }

  bool _isValidRealtimeStatusByte(int b) {
    // Epson: cada status es 0xx1xx10b y se diferencia por bits 0,1,4,7 :contentReference[oaicite:2]{index=2}
    // bits fijos esperados: bit0=0, bit1=1, bit4=1, bit7=0 => máscara 0x93 debe dar 0x12
    return (b & 0x93) == 0x12;
  }

  Future<int?> _readStatusByteWithRetry(
    Uint8List cmd, {
    int retries = 2,
    Duration retryDelay = const Duration(milliseconds: 120),
    Duration timeoutPerAttempt = const Duration(milliseconds: 700),
    String tag = '',
  }) async {
    String fmt(int b) =>
        '0x${b.toRadixString(16).padLeft(2, '0').toUpperCase()}';

    for (var i = 0; i <= retries; i++) {
      final sw = Stopwatch()..start();
      _log('➡️  [$tag] intento ${i + 1}/${retries + 1} send+read');

      Uint8List? rsp;
      try {
        rsp = await _plugin.readStatusUsb(cmd).timeout(timeoutPerAttempt);
      } catch (e) {
        _log('⏱️  [$tag] TIMEOUT/ERROR en ${sw.elapsedMilliseconds}ms: $e');
        await Future.delayed(retryDelay);
        continue;
      }

      _log(
        '⬅️  [$tag] rsp len=${rsp?.length ?? 0} en ${sw.elapsedMilliseconds}ms',
      );

      if (rsp == null || rsp.isEmpty) {
        await Future.delayed(retryDelay);
        continue;
      }

      // Si vienen varios bytes, loguealos para diagnosticar desalineación
      if (rsp.length > 1) {
        final all = rsp.map((b) => fmt(b)).join(', ');
        _log('🔎 [$tag] rsp bytes: [$all]');
      }

      // Elegir el ÚLTIMO byte válido (más probable que sea el “nuevo”)
      for (var idx = rsp.length - 1; idx >= 0; idx--) {
        final b = rsp[idx];
        if (_isValidRealtimeStatusByte(b)) {
          _log('✅ [$tag] byte válido elegido: ${fmt(b)} (idx=$idx)');
          return b;
        }
      }

      // Ninguno válido
      final all = rsp.map((b) => fmt(b)).join(', ');
      _log('⚠️  [$tag] Ningún byte válido. Recibido: [$all]');

      await Future.delayed(retryDelay);
    }

    _log('❌ [$tag] sin respuesta válida tras ${retries + 1} intentos');
    return null;
  }

  PrinterStatus _interpretBytes({
    required int onlineByte,
    required int? paperByte,
    required int? offlineByte,
  }) {
    _log('📋 BYTES (raw):');
    _log(
      '   Online:  0x${onlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()} = ${_toBinaryString(onlineByte)}',
    );
    _log(
      '   Paper:   ${paperByte == null ? 'null' : '0x${paperByte.toRadixString(16).padLeft(2, '0').toUpperCase()} = ${_toBinaryString(paperByte)}'}',
    );
    _log(
      '   Offline: ${offlineByte == null ? 'null' : '0x${offlineByte.toRadixString(16).padLeft(2, '0').toUpperCase()} = ${_toBinaryString(offlineByte)}'}',
    );

    // EOT1 bit3: 0 Online / 1 Offline :contentReference[oaicite:3]{index=3}
    final isOnline = (onlineByte & 0x08) == 0;

    // Papel (EOT4 bits 5&6 == 11 => paper not present) :contentReference[oaicite:4]{index=4}
    bool? hasPaper;
    if (paperByte != null) {
      final paperOut = (paperByte & 0x60) == 0x60;
      hasPaper = !paperOut;
    }

    // Tapa/Error (EOT2 bit2 cover open, bit6 error occurred) :contentReference[oaicite:5]{index=5}
    bool? isCoverOpen;
    bool? hasOfflineError;

    if (!isOnline) {
      if (offlineByte != null) {
        isCoverOpen = (offlineByte & 0x04) != 0;
        hasOfflineError = (offlineByte & 0x40) != 0;
      } else {
        isCoverOpen = null; // UNKNOWN (clave para tu caso)
        hasOfflineError = null; // UNKNOWN
      }
    } else {
      // si está online, no afirmamos nada sobre tapa basado en EOT2
      isCoverOpen = false;
      hasOfflineError = false;
    }

    _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    _log('📊 ESTADO FINAL:');
    _log('   Online: ${isOnline ? '✅' : '❌'}');
    _log(
      '   Papel:  ${hasPaper == null ? '❔ Unknown' : (hasPaper ? '✅' : '❌')}',
    );
    _log(
      '   Tapa:   ${isCoverOpen == null ? '❔ Unknown' : (isCoverOpen ? '❌ Abierta' : '✅ Cerrada')}',
    );
    _log(
      '   Error:  ${hasOfflineError == null ? '❔ Unknown' : (hasOfflineError ? '❌' : '✅')}',
    );
    _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    // Prioridades UX (bloqueantes)
    if (isCoverOpen == true) {
      return PrinterStatus.withError(
        PrinterErrorType.coverOpen,
        'La tapa de la impresora está abierta',
      );
    }

    if (hasPaper == false) {
      return PrinterStatus.withError(
        PrinterErrorType.paperOut,
        'Sin papel en la impresora',
      );
    }

    if (!isOnline) {
      // Offline pero sin detalle (esto es tu TM-T20IIIL típico si no responde EOT2)
      if (hasOfflineError == true) {
        return PrinterStatus.withError(
          PrinterErrorType.communicationError,
          'Error de impresora (offline)',
        );
      }
      if (isCoverOpen == null || hasOfflineError == null || hasPaper == null) {
        return PrinterStatus.withError(
          PrinterErrorType.offline,
          'Impresora offline (lectura incompleta). Posible tapa abierta o condición BUSY.',
        );
      }
      return PrinterStatus.withError(
        PrinterErrorType.offline,
        'Impresora fuera de línea',
      );
    }

    // Online: si no pudimos leer papel, marcá “inestable” (tu decisión UX)
    if (hasPaper == null) {
      return PrinterStatus.withError(
        PrinterErrorType.communicationError,
        'Lectura inestable (sin respuesta a sensor de papel)',
      );
    }

    return PrinterStatus(
      isOnline: true,
      hasPaper: true,
      isCoverOpen: false,
      hasError: false,
      lastChecked: DateTime.now(),
    );
  }
}

/// Excepción personalizada para errores del servicio
class PrinterServiceException implements Exception {
  final String message;
  PrinterServiceException(this.message);

  @override
  String toString() => message;
}
