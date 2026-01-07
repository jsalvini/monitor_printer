import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';
import 'package:ti_printer_plugin/ti_printer_plugin.dart';
import '../models/printer_status.dart';

/// Servicio para gestionar todas las operaciones con la impresora
class PrinterService {
  final TiPrinterPlugin _plugin;
  String? _currentDevicePath;

  PrinterService() : _plugin = TiPrinterPlugin();

  /// Obtiene lista de impresoras USB disponible
  Future<List<PrinterDevice>> getAvailablePrinters() async {
    try {
      final devices = await _plugin.getUsbPrinters();
      return devices
          .map(
            (devicePath) => PrinterDevice(
              devicePath: devicePath,
              displayName: _extractDeviceName(devicePath),
              isConnected: devicePath == _currentDevicePath,
            ),
          )
          .toList();
    } catch (e) {
      throw PrinterServiceException('Error al obtener impresoras: $e');
    }
  }

  /// Conecta con una impresora específica
  Future<bool> connect(String devicePath) async {
    try {
      // Cerrar cualquier conexión previa (por si quedó el puerto abierto)
      await _safeCloseUsbPort();
      _currentDevicePath = null;

      final success = await _plugin.openUsbPort(devicePath);

      if (success == true) {
        _currentDevicePath = devicePath;
        return true;
      }

      return false;
    } catch (e) {
      throw PrinterServiceException('Error al conectar con impresora: $e');
    }
  }

  /// Desconecta de la impresora actual
  Future<void> disconnect() async {
    try {
      await _safeCloseUsbPort();
    } catch (_) {
      // Ignorar (puede fallar si el dispositivo ya no existe)
    } finally {
      _currentDevicePath = null;
    }
  }

  /// Lee el estado completo de la impresora (online, papel, tapa, etc.)
  Future<PrinterStatus> checkStatus() async {
    final devicePath = _currentDevicePath;
    if (devicePath == null) {
      return PrinterStatus.withError(
        PrinterErrorType.deviceNotFound,
        'No hay impresora conectada',
      );
    }

    try {
      // Comando DLE EOT 1 (0x10 0x04 0x01) - Estado online
      final onlineCmd = Uint8List.fromList([0x10, 0x04, 0x01]);
      final onlineResponse = await _plugin.readStatusUsb(onlineCmd);

      // Si no hay respuesta, validar si el dispositivo sigue presente en el sistema
      if (onlineResponse == null || onlineResponse.isEmpty) {
        final present = await _isDevicePresent(devicePath);
        if (!present) {
          await _safeCloseUsbPort();
          _currentDevicePath = null;
          return PrinterStatus.withError(
            PrinterErrorType.deviceNotFound,
            'Impresora desconectada',
          );
        }

        return PrinterStatus.withError(
          PrinterErrorType.offline,
          'Impresora no responde',
        );
      }

      // Comando DLE EOT 4 (0x10 0x04 0x04) - Estado del papel
      final paperCmd = Uint8List.fromList([0x10, 0x04, 0x04]);
      final paperResponse = await _plugin.readStatusUsb(paperCmd);

      // Comando DLE EOT 2 (0x10 0x04 0x02) - Causa de offline
      final offlineCmd = Uint8List.fromList([0x10, 0x04, 0x02]);
      final offlineResponse = await _plugin.readStatusUsb(offlineCmd);

      final status = _interpretStatus(
        onlineResponse,
        paperResponse,
        offlineResponse,
      );

      // Si el status resultó "no responde", validar presencia del devicePath (apagado/desconectado)
      if (status.hasError &&
          status.errorType == PrinterErrorType.offline &&
          status.errorMessage == 'Impresora no responde') {
        final present = await _isDevicePresent(devicePath);
        if (!present) {
          await _safeCloseUsbPort();
          _currentDevicePath = null;
          return PrinterStatus.withError(
            PrinterErrorType.deviceNotFound,
            'Impresora desconectada',
          );
        }
      }

      return status;
    } catch (e) {
      final present = await _isDevicePresent(devicePath);
      if (!present) {
        await _safeCloseUsbPort();
        _currentDevicePath = null;
        return PrinterStatus.withError(
          PrinterErrorType.deviceNotFound,
          'Impresora desconectada',
        );
      }

      return PrinterStatus.withError(
        PrinterErrorType.communicationError,
        'Error de comunicación con impresora: $e',
      );
    }
  }

  /// Envía datos raw a la impresora
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

  /// Verifica si hay una impresora conectada
  bool get isConnected => _currentDevicePath != null;

  /// Obtiene el path del dispositivo actual
  String? get currentDevicePath => _currentDevicePath;

  // ==================== HELPERS ====================

  Future<void> _safeCloseUsbPort() async {
    try {
      //await _plugin.closeUsbPort();
      log('Cerrar puerto USB');
    } catch (_) {
      // Ignorar
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

  // ==================== MÉTODOS PRIVADOS ====================

  String _extractDeviceName(String devicePath) {
    final parts = devicePath.split('/');
    return parts.isNotEmpty ? parts.last : devicePath;
  }

  PrinterStatus _interpretStatus(
    Uint8List? onlineResponse,
    Uint8List? paperResponse,
    Uint8List? offlineResponse,
  ) {
    // Si no hay respuesta, la impresora no está comunicando
    if (onlineResponse == null || onlineResponse.isEmpty) {
      return PrinterStatus.withError(
        PrinterErrorType.offline,
        'Impresora no responde',
      );
    }

    final onlineByte = onlineResponse[0];
    final paperByte = paperResponse != null && paperResponse.isNotEmpty
        ? paperResponse[0]
        : 0xFF;
    final offlineByte = offlineResponse != null && offlineResponse.isNotEmpty
        ? offlineResponse[0]
        : 0x00;

    // Interpretar bits según especificación ESC/POS
    final isOnline = (onlineByte & 0x08) == 0; // Bit 3: 0=online, 1=offline
    final hasPaper = (paperByte & 0x60) != 0x60; // Bits 5-6: papel presente
    final isCoverOpen = (offlineByte & 0x04) != 0; // Bit 2: tapa abierta

    // Detectar error específico
    if (isCoverOpen) {
      return PrinterStatus.withError(
        PrinterErrorType.coverOpen,
        'La tapa de la impresora está abierta',
      );
    }

    if (!hasPaper) {
      return PrinterStatus.withError(
        PrinterErrorType.paperOut,
        'Sin papel en la impresora',
      );
    }

    if (!isOnline) {
      return PrinterStatus.withError(
        PrinterErrorType.offline,
        'Impresora fuera de línea',
      );
    }

    // Estado saludable
    return PrinterStatus(
      isOnline: isOnline,
      hasPaper: hasPaper,
      isCoverOpen: isCoverOpen,
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
