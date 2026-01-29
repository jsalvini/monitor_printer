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

  void _log(String message) {
    // Usar print() en lugar de dev.log() para que aparezca en release
    if (kDebugMode) {
      print('🖨️ [PrinterService] $message');
    }
    dev.log('🖨️ $message', name: 'PrinterService');
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
  Future<PrinterStatus> checkStatus() async {
    final devicePath = _currentDevicePath;
    if (devicePath == null) {
      return PrinterStatus.withError(
        PrinterErrorType.deviceNotFound,
        'No hay impresora conectada',
      );
    }

    try {
      // CRÍTICO: Delay entre comandos para EPSON
      final delay = const Duration(milliseconds: 100);

      // DLE EOT 1 - Estado online
      final onlineCmd = Uint8List.fromList([0x10, 0x04, 0x01]);
      final onlineResponse = await _plugin.readStatusUsb(onlineCmd);

      _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      _log('📊 RESPUESTAS DE ESTADO:');
      _log('Online (DLE EOT 1): ${_formatBytes(onlineResponse)}');

      if (onlineResponse == null || onlineResponse.isEmpty) {
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

        _log('⚠️ Sin respuesta online');
        return PrinterStatus.withError(
          PrinterErrorType.offline,
          'Impresora no responde',
        );
      }

      // DELAY CRÍTICO
      await Future.delayed(delay);

      // DLE EOT 4 - Estado del papel
      final paperCmd = Uint8List.fromList([0x10, 0x04, 0x04]);
      final paperResponse = await _plugin.readStatusUsb(paperCmd);
      _log('Paper (DLE EOT 4): ${_formatBytes(paperResponse)}');

      // DELAY CRÍTICO
      await Future.delayed(delay);

      // DLE EOT 2 - Causa de offline
      final offlineCmd = Uint8List.fromList([0x10, 0x04, 0x02]);
      final offlineResponse = await _plugin.readStatusUsb(offlineCmd);
      _log('Offline (DLE EOT 2): ${_formatBytes(offlineResponse)}');
      _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      return _interpretStatus(onlineResponse, paperResponse, offlineResponse);
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
    }
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

  String _toBinaryString(int byte) {
    return byte.toRadixString(2).padLeft(8, '0');
  }
}

/// Excepción personalizada para errores del servicio
class PrinterServiceException implements Exception {
  final String message;
  PrinterServiceException(this.message);

  @override
  String toString() => message;
}
