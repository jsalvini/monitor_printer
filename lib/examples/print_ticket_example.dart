import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/printer_bloc.dart';
import '../services/printer_service.dart';

/// Ejemplo de cómo imprimir un ticket después de validar la impresora
class PrintTicketExample extends StatelessWidget {
  const PrintTicketExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ejemplo de Impresión')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Este ejemplo muestra cómo imprimir un ticket validando '
              'el estado de la impresora en cada paso.',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => _printTicketWithValidation(context),
              child: const Text('Imprimir Ticket de Prueba'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _demonstrateCheckpoints(context),
              child: const Text('Demostrar Validación en Checkpoints'),
            ),
          ],
        ),
      ),
    );
  }

  /// Ejemplo completo de impresión con validación
  Future<void> _printTicketWithValidation(BuildContext context) async {
    final bloc = context.read<PrinterBloc>();

    // 1. Mostrar diálogo de carga
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Preparando impresión...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      // 2. Validar estado de la impresora
      final isReady = await bloc.validateBeforeCriticalPoint('impresion');

      if (!isReady) {
        if (context.mounted) {
          Navigator.pop(context); // Cerrar diálogo de carga
          _showErrorDialog(
            context,
            'Impresora No Lista',
            'La impresora no está disponible para imprimir. '
                'Por favor, verifica el estado.',
          );
        }

        return;
      }

      // 3. Generar datos del ticket
      final ticketData = _generateSampleTicket();

      // 4. Enviar a la impresora
      final service = PrinterService();
      final success = await service.sendRawData(ticketData);

      if (!context.mounted) return;
      Navigator.pop(context); // Cerrar diálogo de carga

      if (success) {
        _showSuccessDialog(context, 'Ticket impreso correctamente');
      } else {
        _showErrorDialog(
          context,
          'Error de Impresión',
          'No se pudo enviar los datos a la impresora.',
        );
      }
    } catch (e) {
      Navigator.pop(context); // Cerrar diálogo de carga
      _showErrorDialog(context, 'Error', 'Ocurrió un error al imprimir: $e');
    }
  }

  /// Ejemplo de validación en múltiples checkpoints
  Future<void> _demonstrateCheckpoints(BuildContext context) async {
    final bloc = context.read<PrinterBloc>();
    final messenger = ScaffoldMessenger.of(context);

    // Checkpoint 1: Inicio de Ticket
    messenger.showSnackBar(
      const SnackBar(content: Text('Validando: Inicio de Ticket...')),
    );
    await Future.delayed(const Duration(seconds: 1));

    bool isReady = await bloc.validateBeforeCriticalPoint('inicio_ticket');
    if (!isReady) {
      if (!context.mounted) return;
      _showCheckpointError(context, 'Inicio de Ticket');
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text('✓ Checkpoint 1: OK'),
        backgroundColor: Colors.green,
      ),
    );

    // Checkpoint 2: Selección de Pago
    await Future.delayed(const Duration(seconds: 1));
    messenger.showSnackBar(
      const SnackBar(content: Text('Validando: Selección de Pago...')),
    );
    await Future.delayed(const Duration(seconds: 1));

    isReady = await bloc.validateBeforeCriticalPoint('seleccion_pago');
    if (!isReady) {
      if (!context.mounted) return;
      _showCheckpointError(context, 'Selección de Pago');
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text('✓ Checkpoint 2: OK'),
        backgroundColor: Colors.green,
      ),
    );

    // Checkpoint 3: Impresión Final
    await Future.delayed(const Duration(seconds: 1));
    messenger.showSnackBar(
      const SnackBar(content: Text('Validando: Impresión...')),
    );
    await Future.delayed(const Duration(seconds: 1));

    isReady = await bloc.validateBeforeCriticalPoint('impresion');
    if (!isReady) {
      if (!context.mounted) return;
      _showCheckpointError(context, 'Impresión');
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text('✓ Checkpoint 3: OK - Todos los checkpoints pasados!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ),
    );
    if (!context.mounted) return;
    _showSuccessDialog(
      context,
      'Todos los checkpoints de validación fueron exitosos',
    );
  }

  /// Genera un ticket de prueba simple en ESC/POS
  Uint8List _generateSampleTicket() {
    // Comandos ESC/POS básicos
    final List<int> commands = [];

    // ESC @ - Inicializar impresora
    commands.addAll([0x1B, 0x40]);

    // ESC a 1 - Alinear al centro
    commands.addAll([0x1B, 0x61, 0x01]);

    // Texto: "TICKET DE PRUEBA"
    commands.addAll('TICKET DE PRUEBA\n'.codeUnits);

    // ESC E 1 - Negrita ON
    commands.addAll([0x1B, 0x45, 0x01]);
    commands.addAll('AUTOSERVICIO\n'.codeUnits);
    // ESC E 0 - Negrita OFF
    commands.addAll([0x1B, 0x45, 0x00]);

    // Línea separadora
    commands.addAll('\n'.codeUnits);
    commands.addAll('--------------------------------\n'.codeUnits);
    commands.addAll('\n'.codeUnits);

    // ESC a 0 - Alinear a la izquierda
    commands.addAll([0x1B, 0x61, 0x00]);

    // Contenido del ticket
    commands.addAll('Fecha: 2025-01-07\n'.codeUnits);
    commands.addAll('Hora: 10:30\n'.codeUnits);
    commands.addAll('Ticket: #00123\n'.codeUnits);
    commands.addAll('\n'.codeUnits);

    // Items de ejemplo
    commands.addAll('Item 1          \$10.00\n'.codeUnits);
    commands.addAll('Item 2          \$15.50\n'.codeUnits);
    commands.addAll('Item 3           \$5.00\n'.codeUnits);

    commands.addAll('\n'.codeUnits);
    commands.addAll('--------------------------------\n'.codeUnits);

    // Total
    commands.addAll([0x1B, 0x45, 0x01]); // Negrita ON
    commands.addAll('TOTAL           \$30.50\n'.codeUnits);
    commands.addAll([0x1B, 0x45, 0x00]); // Negrita OFF

    commands.addAll('\n'.codeUnits);

    // ESC a 1 - Centrar
    commands.addAll([0x1B, 0x61, 0x01]);
    commands.addAll('Gracias por su compra!\n'.codeUnits);
    commands.addAll('\n\n\n'.codeUnits);

    // GS V 66 0 - Corte de papel
    commands.addAll([0x1D, 0x56, 0x42, 0x00]);

    return Uint8List.fromList(commands);
  }

  void _showCheckpointError(BuildContext context, String checkpoint) {
    _showErrorDialog(
      context,
      'Error en Checkpoint',
      'La validación falló en: $checkpoint\n\n'
          'La impresora no está lista. Por favor, verifica su estado.',
    );
  }

  void _showErrorDialog(BuildContext context, String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.error, color: Colors.red, size: 48),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSuccessDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('Éxito'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

// ========== Ejemplo de integración en tu flujo de autoservicio ==========

/// Clase de ejemplo que muestra cómo integrar las validaciones
/// en un flujo real de autoservicio
class AutoservicioFlowExample {
  final PrinterBloc printerBloc;

  AutoservicioFlowExample(this.printerBloc);

  /// Paso 1: Usuario inicia un nuevo pedido
  Future<bool> startNewOrder() async {
    // Validar impresora antes de comenzar
    final isReady = await printerBloc.validateBeforeCriticalPoint(
      'inicio_pedido',
    );

    if (!isReady) {
      // Mostrar error al usuario
      return false;
    }

    // Continuar con el flujo...
    return true;
  }

  /// Paso 2: Usuario selecciona productos
  Future<void> selectProducts() async {
    // Aquí no es necesario validar, el usuario está navegando
  }

  /// Paso 3: Usuario procede al pago
  Future<bool> proceedToPayment() async {
    // Validar impresora antes de ir a pago
    final isReady = await printerBloc.validateBeforeCriticalPoint(
      'proceder_pago',
    );

    if (!isReady) {
      return false;
    }

    return true;
  }

  /// Paso 4: Usuario completa el pago
  Future<bool> completePayment() async {
    // Validar antes de imprimir el ticket
    final isReady = await printerBloc.validateBeforeCriticalPoint(
      'completar_pago',
    );

    if (!isReady) {
      return false;
    }

    return true;
  }

  /// Paso 5: Imprimir ticket final
  Future<bool> printFinalTicket(/* datos del pedido */) async {
    // Última validación antes de imprimir
    final isReady = await printerBloc.validateBeforeCriticalPoint(
      'imprimir_ticket',
    );

    if (!isReady) {
      return false;
    }

    // Generar y enviar ticket
    // final ticketData = generateTicket(...);
    // await printerService.sendRawData(ticketData);

    return true;
  }
}
