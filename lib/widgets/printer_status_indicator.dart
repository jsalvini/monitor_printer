import 'package:flutter/material.dart';
import '../models/printer_status.dart';

/// Widget que muestra el estado visual de la impresora
class PrinterStatusIndicator extends StatelessWidget {
  final PrinterStatus? status;
  final PrinterConnectionStatus connectionStatus;
  final bool isCompact;

  const PrinterStatusIndicator({
    super.key,
    required this.status,
    required this.connectionStatus,
    this.isCompact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return _buildCompactView(context);
    }
    return _buildDetailedView(context);
  }

  Widget _buildCompactView(BuildContext context) {
    final color = _getStatusColor();
    final icon = _getStatusIcon();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 6),
          Text(
            _getStatusText(),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailedView(BuildContext context) {
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
                Icon(
                  Icons.print,
                  size: 24,
                  color: Theme.of(context).primaryColor,
                ),
                const SizedBox(width: 8),
                Text(
                  'Estado de la Impresora',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildStatusRow(
              icon: Icons.power_settings_new,
              label: 'Conexión',
              value: _getConnectionText(),
              color: _getStatusColor(),
            ),
            if (status != null) ...[
              const Divider(height: 24),
              _buildStatusRow(
                icon: Icons.check_circle,
                label: 'Estado',
                value: status!.isOnline ? 'En línea' : 'Fuera de línea',
                color: status!.isOnline ? Colors.green : Colors.red,
              ),
              const SizedBox(height: 8),
              _buildStatusRow(
                icon: Icons.description,
                label: 'Papel',
                value: status!.hasPaper ? 'Disponible' : 'Sin papel',
                color: status!.hasPaper ? Colors.green : Colors.orange,
              ),
              const SizedBox(height: 8),
              _buildStatusRow(
                icon: Icons.door_back_door,
                label: 'Tapa',
                value: status!.isCoverOpen ? 'Abierta' : 'Cerrada',
                color: status!.isCoverOpen ? Colors.orange : Colors.green,
              ),
              if (status!.hasError) ...[
                const Divider(height: 24),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: Colors.red.shade700),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          status!.errorMessage ?? 'Error desconocido',
                          style: TextStyle(
                            color: Colors.red.shade900,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Última verificación: ${_formatLastChecked()}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Color _getStatusColor() {
    if (connectionStatus != PrinterConnectionStatus.connected) {
      return Colors.grey;
    }

    if (status == null) return Colors.grey;
    if (status!.hasError) return Colors.red;
    if (status!.isReadyToPrint) return Colors.green;
    return Colors.orange;
  }

  IconData _getStatusIcon() {
    if (connectionStatus == PrinterConnectionStatus.connecting) {
      return Icons.sync;
    }
    if (connectionStatus != PrinterConnectionStatus.connected) {
      return Icons.close;
    }

    if (status == null) return Icons.help;
    if (status!.hasError) return Icons.error;
    if (status!.isReadyToPrint) return Icons.check_circle;
    return Icons.warning;
  }

  String _getStatusText() {
    if (connectionStatus == PrinterConnectionStatus.connecting) {
      return 'Conectando...';
    }
    if (connectionStatus != PrinterConnectionStatus.connected) {
      return 'Desconectada';
    }

    if (status == null) return 'Desconocido';
    if (status!.isReadyToPrint) return 'Lista';
    return status!.statusMessage;
  }

  String _getConnectionText() {
    switch (connectionStatus) {
      case PrinterConnectionStatus.connected:
        return 'Conectada';
      case PrinterConnectionStatus.connecting:
        return 'Conectando...';
      case PrinterConnectionStatus.disconnected:
        return 'Desconectada';
      case PrinterConnectionStatus.error:
        return 'Error';
    }
  }

  String _formatLastChecked() {
    if (status == null) return '-';

    final now = DateTime.now();
    final diff = now.difference(status!.lastChecked);

    if (diff.inSeconds < 60) {
      return 'Hace ${diff.inSeconds}s';
    } else if (diff.inMinutes < 60) {
      return 'Hace ${diff.inMinutes}m';
    } else {
      return 'Hace ${diff.inHours}h';
    }
  }
}
