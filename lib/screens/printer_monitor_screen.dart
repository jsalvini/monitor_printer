import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/printer_bloc.dart';
import '../bloc/printer_event.dart';
import '../bloc/printer_state.dart';
import '../models/printer_status.dart';
import '../widgets/printer_status_indicator.dart';

/// Pantalla principal del monitor de impresora (MVP)
class PrinterMonitorScreen extends StatelessWidget {
  const PrinterMonitorScreen({super.key});

  bool _isDisconnectError(PrinterBlocState state) {
    final type = state.printerStatus?.errorType;
    if (type == PrinterErrorType.deviceNotFound ||
        type == PrinterErrorType.communicationError) {
      return true;
    }

    final msg = state.displayErrorMessage?.toLowerCase() ?? '';
    if (state.connectionStatus != PrinterConnectionStatus.connected &&
        (msg.contains('desconect') || msg.contains('no hay impresora'))) {
      return true;
    }

    return false;
  }

  bool _shouldShowReconnectChip(PrinterBlocState state) {
    // Se muestra cuando la desconexión fue por pérdida del dispositivo/comunicación
    // y si hay una impresora seleccionada el sistema intentará reconectar.
    if (!_isDisconnectError(state)) return false;
    if (state.selectedPrinter == null) return false;

    return state.connectionStatus == PrinterConnectionStatus.disconnected ||
        state.connectionStatus == PrinterConnectionStatus.connecting;
  }

  Widget _buildPrintChip(PrinterBlocState state) {
    switch (state.printStatus) {
      case PrintStatus.printing:
        return const Chip(
          avatar: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: Text('Imprimiendo…'),
        );

      case PrintStatus.success:
        return Chip(
          avatar: const Icon(Icons.check_circle, size: 18),
          label: Text(state.printMessage ?? 'Impresión OK'),
        );

      case PrintStatus.error:
        return Chip(
          avatar: const Icon(Icons.error, size: 18),
          label: Text(state.printMessage ?? 'Error al imprimir'),
        );

      case PrintStatus.idle:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monitor de Impresora'),
        centerTitle: true,
        elevation: 0,
        actions: [
          BlocBuilder<PrinterBloc, PrinterBlocState>(
            builder: (context, state) {
              return IconButton(
                icon: Icon(
                  state.isMonitoring ? Icons.stop_circle : Icons.play_circle,
                ),
                tooltip: state.isMonitoring
                    ? 'Detener monitoreo'
                    : 'Iniciar monitoreo',
                onPressed: () {
                  if (state.isMonitoring) {
                    context.read<PrinterBloc>().add(StopMonitoringEvent());
                  } else {
                    context.read<PrinterBloc>().add(
                      const StartMonitoringEvent(),
                    );
                  }
                },
              );
            },
          ),
        ],
      ),
      body: BlocConsumer<PrinterBloc, PrinterBlocState>(
        listenWhen: (previous, current) {
          final prevMsg = previous.displayErrorMessage;
          final currMsg = current.displayErrorMessage;

          // Solo reaccionar cuando el mensaje cambia.
          if (currMsg == null) return false;
          if (prevMsg == currMsg) return false;

          // La desconexión se muestra en pantalla.
          return !_isDisconnectError(current);
        },
        listener: (context, state) {
          final message = state.displayErrorMessage;
          if (message == null) return;

          final messenger = ScaffoldMessenger.of(context);
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(child: Text(message)),
                ],
              ),
              backgroundColor: Colors.red.shade700,
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'OK',
                textColor: Colors.white,
                onPressed: () {
                  context.read<PrinterBloc>().add(ClearErrorEvent());
                },
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        },
        builder: (context, state) {
          return SafeArea(
            child: Column(
              children: [
                // Indicador de estado compacto en la parte superior
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.grey.shade100,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: PrinterStatusIndicator(
                          status: state.printerStatus,
                          connectionStatus: state.connectionStatus,
                          isCompact: true,
                        ),
                      ),
                      if (_isDisconnectError(state))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.usb_off,
                                size: 16,
                                color: Colors.red.shade700,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Impresora desconectada',
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (state.printStatus != PrintStatus.idle)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Center(child: _buildPrintChip(state)),
                        ),
                      if (_shouldShowReconnectChip(state))
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Center(
                            child: Chip(
                              avatar: const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              label: const Text('Reconectando…'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Selector de impresora
                        _PrinterSelector(
                          availablePrinters: state.availablePrinters,
                          selectedPrinter: state.selectedPrinter,
                          isLoading: state.isLoading,
                          isConnected:
                              state.connectionStatus ==
                              PrinterConnectionStatus.connected,
                        ),

                        const SizedBox(height: 24),

                        // Estado detallado
                        PrinterStatusIndicator(
                          status: state.printerStatus,
                          connectionStatus: state.connectionStatus,
                        ),

                        const SizedBox(height: 24),

                        // Botones de acción
                        _ActionButtons(state: state),

                        const SizedBox(height: 24),

                        // Botón principal "COMENZAR"
                        _StartButton(canStart: state.canStartApp),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Widget para seleccionar la impresora
class _PrinterSelector extends StatelessWidget {
  final List<PrinterDevice> availablePrinters;
  final PrinterDevice? selectedPrinter;
  final bool isLoading;
  final bool isConnected;

  const _PrinterSelector({
    required this.availablePrinters,
    required this.selectedPrinter,
    required this.isLoading,
    required this.isConnected,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.usb, color: Theme.of(context).primaryColor),
                const SizedBox(width: 8),
                Text(
                  'Impresora',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                if (isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: isConnected
                        ? null
                        : () {
                            context.read<PrinterBloc>().add(
                              LoadPrintersEvent(),
                            );
                          },
                    tooltip: 'Buscar impresoras',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (availablePrinters.isEmpty)
              const Text(
                'No se encontraron impresoras. Conecta una impresora USB y presiona actualizar.',
                style: TextStyle(color: Colors.grey),
              )
            else
              Builder(
                builder: (context) {
                  final selectedValue =
                      selectedPrinter != null &&
                          availablePrinters.any(
                            (p) => p.devicePath == selectedPrinter!.devicePath,
                          )
                      ? selectedPrinter!.devicePath
                      : null;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: selectedValue,
                        decoration: InputDecoration(
                          labelText: 'Seleccionar impresora',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          prefixIcon: const Icon(Icons.print),
                        ),
                        items: availablePrinters.map((printer) {
                          return DropdownMenuItem(
                            value: printer.devicePath,
                            child: Text(printer.displayName),
                          );
                        }).toList(),
                        onChanged: isConnected
                            ? null
                            : (value) {
                                if (value != null) {
                                  context.read<PrinterBloc>().add(
                                    SelectPrinterEvent(value),
                                  );
                                }
                              },
                      ),

                      if (selectedPrinter != null && selectedValue == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Última seleccionada: ${selectedPrinter!.displayName} (el puerto puede cambiar al reconectar)',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Botones de acción (conectar, desconectar, verificar)
class _ActionButtons extends StatelessWidget {
  final PrinterBlocState state;

  const _ActionButtons({required this.state});

  @override
  Widget build(BuildContext context) {
    final isConnected =
        state.connectionStatus == PrinterConnectionStatus.connected;
    final canConnect = state.selectedPrinter != null && !isConnected;

    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: canConnect && !state.isLoading
                ? () {
                    context.read<PrinterBloc>().add(ConnectPrinterEvent());
                  }
                : null,
            icon: const Icon(Icons.link),
            label: const Text('Conectar'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: isConnected && !state.isLoading
                ? () {
                    context.read<PrinterBloc>().add(DisconnectPrinterEvent());
                  }
                : null,
            icon: const Icon(Icons.link_off),
            label: const Text('Desconectar'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed:
                isConnected &&
                    !state.isLoading &&
                    state.printStatus != PrintStatus.printing
                ? () =>
                      context.read<PrinterBloc>().add(const PrintTicketEvent())
                : null,

            icon: const Icon(Icons.receipt_long),
            label: const Text('Imprimir prueba'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        IconButton.filled(
          onPressed: isConnected && !state.isLoading
              ? () {
                  context.read<PrinterBloc>().add(CheckStatusEvent());
                }
              : null,
          icon: const Icon(Icons.refresh),
          tooltip: 'Verificar estado',
        ),
      ],
    );
  }
}

/// Botón principal para comenzar (simula el inicio de la app)
class _StartButton extends StatelessWidget {
  final bool canStart;

  const _StartButton({required this.canStart});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: ElevatedButton(
        onPressed: canStart
            ? () {
                _showStartDialog(context);
              }
            : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: canStart ? Colors.green : Colors.grey,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: canStart ? 4 : 0,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(canStart ? Icons.check_circle : Icons.block, size: 28),
            const SizedBox(width: 12),
            Text(
              canStart ? 'COMENZAR' : 'IMPRESORA NO LISTA',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showStartDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        title: const Text('¡Impresora Lista!'),
        content: const Text(
          'La impresora está conectada y lista para usar.\n\n'
          'En tu aplicación real, aquí comenzarías el flujo principal.',
        ),
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
