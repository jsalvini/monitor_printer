import 'dart:async';
import 'dart:typed_data';
import 'package:ti_printer_plugin/ti_printer_plugin.dart';
import '../models/printer_status.dart';

/// Servicio para gestionar todas las operaciones con la impresora
class PrinterService {
  final TiPrinterPlugin _plugin;
  String? _currentDevicePath;

  PrinterService() : _plugin = TiPrinterPlugin();

  /// Obtiene lista de impresoras USB disponibles
  Future<List<PrinterDevice>> getAvailablePrinters() async {
    try {
      final devices = await _plugin.getUsbPrinters();
      return devices.map((devicePath) {
        // Extraer nombre más legible del path
        final name = _extractDeviceName(devicePath);
        return PrinterDevice(
          devicePath: devicePath,
          displayName: name,
          isConnected: devicePath == _currentDevicePath,
        );
      }).toList();
    } catch (e) {
      throw PrinterServiceException('Error al listar impresoras: $e');
    }
  }

  /// Conecta con una impresora específica
  Future<bool> connect(String devicePath) async {
    try {
      // Cerrar conexión previa si existe
      if (_currentDevicePath != null) {
        await disconnect();
      }

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
      if (_currentDevicePath != null) {
        //await _plugin.closeUsbPort();
        _currentDevicePath = null;
      }
    } catch (e) {
      throw PrinterServiceException('Error al desconectar impresora: $e');
    }
  }

  /// Lee el estado completo de la impresora
  Future<PrinterStatus> checkStatus() async {
    if (_currentDevicePath == null) {
      return PrinterStatus.withError(
        PrinterErrorType.deviceNotFound,
        'No hay impresora conectada',
      );
    }

    try {
      // Comando DLE EOT 1 (0x10 0x04 0x01) - Estado online
      final onlineCmd = Uint8List.fromList([0x10, 0x04, 0x01]);
      final onlineResponse = await _plugin.readStatusUsb(onlineCmd);

      // Comando DLE EOT 4 (0x10 0x04 0x04) - Estado del papel
      final paperCmd = Uint8List.fromList([0x10, 0x04, 0x04]);
      final paperResponse = await _plugin.readStatusUsb(paperCmd);

      // Comando DLE EOT 2 (0x10 0x04 0x02) - Causa de offline
      final offlineCmd = Uint8List.fromList([0x10, 0x04, 0x02]);
      final offlineResponse = await _plugin.readStatusUsb(offlineCmd);

      return _interpretStatus(onlineResponse, paperResponse, offlineResponse);
    } catch (e) {
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

  /// Verifica si hay una impresora conectada
  bool get isConnected => _currentDevicePath != null;

  /// Obtiene el path del dispositivo actual
  String? get currentDevicePath => _currentDevicePath;

  // ==================== MÉTODOS PRIVADOS ====================

  String _extractDeviceName(String devicePath) {
    // Extraer nombre legible del path
    // Ejemplo: /dev/usb/lp1 -> "USB Printer LP1"
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
  String toString() => 'PrinterServiceException: $message';
}
